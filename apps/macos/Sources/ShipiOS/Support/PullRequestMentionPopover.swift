import AppKit
import SwiftUI

/// A window-content overlay escapes scroll clipping and never takes editor focus.
struct PullRequestMentionPopover: NSViewRepresentable {
  let state: GitHubPRMentionState
  let enabled: Bool
  @Environment(\.appAppearance) private var appearance
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> AnchorView {
    let view = AnchorView(); view.owner = context.coordinator; return view
  }
  func updateNSView(_ view: AnchorView, context: Context) {
    context.coordinator.parent = self
    context.coordinator.needsRootUpdate = true
    context.coordinator.schedule(view)
  }
  static func dismantleNSView(_ view: AnchorView, coordinator: Coordinator) {
    coordinator.active = false; coordinator.detach(); view.owner = nil
  }
  static func placement(anchor: NSRect, viewport: NSRect, height: CGFloat) -> NSRect? {
    let available = viewport.insetBy(dx: 6, dy: 6)
    guard anchor.intersects(available), available.width > 0 else { return nil }
    let above = max(0, available.maxY - anchor.maxY - 8), below = max(0, anchor.minY - available.minY - 8)
    let useAbove = above >= height || above >= below
    let fittedHeight = min(height, useAbove ? above : below)
    guard fittedHeight >= 32 else { return nil }
    let width = min(anchor.width, available.width)
    return NSRect(x: max(available.minX, min(anchor.minX, available.maxX - width)),
      y: useAbove ? anchor.maxY + 8 : anchor.minY - 8 - fittedHeight, width: width, height: fittedHeight)
  }
  final class AnchorView: NSView {
    weak var owner: Coordinator?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); owner?.attach(self) }
    override func layout() { super.layout(); owner?.schedule(self) }
  }
  final class HostingView: NSHostingView<AnyView> {
    override var acceptsFirstResponder: Bool { false }
    override var canBecomeKeyView: Bool { false }
  }
  @MainActor final class Coordinator {
    var parent: PullRequestMentionPopover
    var active = true
    var needsRootUpdate = true
    private var scheduled = false
    private var observers: [NSObjectProtocol] = []
    private var popup: NSHostingView<AnyView>?
    private weak var observedWindow: NSWindow?
    init(_ parent: PullRequestMentionPopover) { self.parent = parent }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
    func detach() {
      observers.forEach { NotificationCenter.default.removeObserver($0) }; observers = []
      popup?.removeFromSuperview(); popup = nil; observedWindow = nil
    }
    func attach(_ anchor: AnchorView) {
      detach()
      guard active, let window = anchor.window else { return }
      observedWindow = window
      var ancestor: NSView? = anchor
      while let view = ancestor {
        view.postsBoundsChangedNotifications = true; view.postsFrameChangedNotifications = true
        for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
          observers.append(NotificationCenter.default.addObserver(forName: name, object: view, queue: .main) { [weak self, weak anchor] _ in
            MainActor.assumeIsolated { if let anchor { self?.schedule(anchor) } }
          })
        }
        ancestor = view.superview
      }
      for name in [NSWindow.didResizeNotification, NSWindow.didEndSheetNotification] {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self, weak anchor] _ in
          MainActor.assumeIsolated { if let anchor { self?.schedule(anchor) } }
        })
      }
      schedule(anchor)
    }
    func schedule(_ anchor: AnchorView) {
      guard active, !scheduled else { return }
      scheduled = true
      DispatchQueue.main.async { [weak self, weak anchor] in
        guard let self else { return }; self.scheduled = false
        if let anchor { self.update(anchor) }
      }
    }
    private func update(_ anchor: AnchorView) {
      guard active else { return }
      if anchor.window !== observedWindow { attach(anchor); return }
      guard parent.enabled, parent.state.visible, !anchor.isHiddenOrHasHiddenAncestor,
        !anchor.bounds.intersection(anchor.visibleRect).isEmpty,
        let window = anchor.window, window.attachedSheet == nil, let content = window.contentView else {
        popup?.removeFromSuperview(); popup = nil; return
      }
      // Convert through window coordinates so flipped SwiftUI/scroll containers do not invert the side.
      let anchorRect = anchor.convert(anchor.bounds, to: nil)
      let viewport = content.convert(content.bounds, to: nil)
      let height = min(320, CGFloat(max(1, parent.state.users.count) * 34 + 8))
      guard let frame = PullRequestMentionPopover.placement(anchor: anchorRect, viewport: viewport, height: height) else {
        popup?.removeFromSuperview(); popup = nil; return
      }
      let root = AnyView(GitHubPRMentionPicker(state: parent.state).environment(\.appAppearance, parent.appearance))
      let host = popup ?? HostingView(rootView: root)
      host.sizingOptions = []
      if popup == nil || needsRootUpdate { host.rootView = root; needsRootUpdate = false }
      let converted = content.convert(frame, from: nil)
      if host.frame != converted { host.frame = converted }
      host.focusRingType = .none
      if host.superview !== content { content.addSubview(host, positioned: .above, relativeTo: nil) }
      popup = host
    }
  }
}
