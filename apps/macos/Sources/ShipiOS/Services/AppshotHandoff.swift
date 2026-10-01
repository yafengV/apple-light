import AppKit
import QuartzCore
import SwiftUI

@MainActor final class AppshotHandoff {
  let imageID: UUID
  weak var ownerWindow: NSWindow?
  let sourceFrame: CGRect
  let screenshot: Data

  init(imageID: UUID, ownerWindow: NSWindow, sourceFrame: CGRect, screenshot: Data) {
    self.imageID = imageID; self.ownerWindow = ownerWindow
    self.sourceFrame = sourceFrame; self.screenshot = screenshot
  }
}

enum AppshotHandoffGeometry {
  struct Display {
    let captureFrame: CGRect
    let appFrame: CGRect
  }

  static func appFrame(for capturedFrame: CGRect, displays: [Display]) -> CGRect? {
    guard capturedFrame.width > 0, capturedFrame.height > 0,
      capturedFrame.minX.isFinite, capturedFrame.minY.isFinite,
      capturedFrame.width.isFinite, capturedFrame.height.isFinite else { return nil }
    guard let display = displays.max(by: {
      overlap($0.captureFrame, capturedFrame) < overlap($1.captureFrame, capturedFrame)
    }), overlap(display.captureFrame, capturedFrame) > 0,
      display.captureFrame.width > 0, display.captureFrame.height > 0,
      display.appFrame.width > 0, display.appFrame.height > 0 else { return nil }
    let xScale = display.appFrame.width / display.captureFrame.width
    let yScale = display.appFrame.height / display.captureFrame.height
    return CGRect(
      x: display.appFrame.minX + (capturedFrame.minX - display.captureFrame.minX) * xScale,
      y: display.appFrame.maxY - (capturedFrame.maxY - display.captureFrame.minY) * yScale,
      width: capturedFrame.width * xScale,
      height: capturedFrame.height * yScale)
  }

  static func appFrame(for capturedFrame: CGRect) -> CGRect? {
    let displays = NSScreen.screens.compactMap { screen -> Display? in
      guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
      else { return nil }
      return Display(captureFrame: CGDisplayBounds(number.uint32Value), appFrame: screen.frame)
    }
    return appFrame(for: capturedFrame, displays: displays)
  }

  private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
    let intersection = a.intersection(b)
    return intersection.isNull ? 0 : intersection.width * intersection.height
  }
}

@MainActor final class AppshotHandoffAnimator {
  private var panel: NSPanel?
  private var activeID: UUID?
  private var completion: (() -> Void)?

  func start(_ handoff: AppshotHandoff, destinationFrame: CGRect,
    completion: @escaping () -> Void) -> Bool {
    guard let sourceFrame = AppshotHandoffGeometry.appFrame(for: handoff.sourceFrame),
      destinationFrame.width > 0, destinationFrame.height > 0,
      destinationFrame.minX.isFinite, destinationFrame.minY.isFinite,
      destinationFrame.width.isFinite, destinationFrame.height.isFinite,
      let screenshot = NSImage(data: handoff.screenshot) else { return false }
    cancel()
    let surface = sourceFrame.union(destinationFrame).insetBy(dx: -24, dy: -24)
    guard surface.width > 0, surface.height > 0, surface.width < 40_000,
      surface.height < 40_000 else { return false }
    let panel = NSPanel(contentRect: surface, styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    let content = NSView(frame: CGRect(origin: .zero, size: surface.size))
    content.wantsLayer = true
    content.layer?.backgroundColor = NSColor.clear.cgColor
    let image = NSImageView(frame: local(sourceFrame, within: surface))
    image.image = screenshot
    image.imageScaling = .scaleProportionallyUpOrDown
    image.wantsLayer = true
    image.layer?.cornerRadius = 10
    image.layer?.masksToBounds = true
    content.addSubview(image)
    panel.contentView = content
    self.panel = panel
    self.activeID = handoff.imageID
    self.completion = completion
    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.55
      context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.72, 0.2, 1)
      image.animator().frame = local(destinationFrame, within: surface)
      image.animator().alphaValue = 0
    } completionHandler: { [weak self] in
      Task { @MainActor in self?.finish(id: handoff.imageID) }
    }
    return true
  }

  func cancel() {
    activeID = nil
    let done = completion
    completion = nil
    panel?.orderOut(nil)
    panel?.close()
    panel = nil
    done?()
  }

  private func finish(id: UUID) {
    guard activeID == id else { return }
    cancel()
  }

  private func local(_ rect: CGRect, within surface: CGRect) -> CGRect {
    CGRect(x: rect.minX - surface.minX, y: rect.minY - surface.minY,
      width: rect.width, height: rect.height)
  }
}

struct AppshotHandoffAnchor: NSViewRepresentable {
  let imageID: UUID
  let store: WorkspaceStore

  func makeNSView(context: Context) -> AnchorView { AnchorView() }
  func updateNSView(_ view: AnchorView, context: Context) {
    view.report = { [weak store] frame, window in
      store?.startAppshotHandoff(imageID: imageID, destinationFrame: frame, window: window)
    }
    view.schedule()
  }
  static func dismantleNSView(_ view: AnchorView, coordinator: ()) { view.report = nil }

  @MainActor final class AnchorView: NSView {
    var report: ((CGRect, NSWindow) -> Void)?
    private var scheduled = false
    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); schedule() }
    override func layout() { super.layout(); schedule() }
    func schedule() {
      guard !scheduled else { return }
      scheduled = true
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.scheduled = false
        guard let window = self.window, self.bounds.width > 0, self.bounds.height > 0 else { return }
        let visible = self.bounds.intersection(self.visibleRect)
        guard !visible.isNull, visible.width >= self.bounds.width * 0.5,
          visible.height >= self.bounds.height * 0.5 else { return }
        self.report?(window.convertToScreen(self.convert(self.bounds, to: nil)), window)
      }
    }
  }
}
