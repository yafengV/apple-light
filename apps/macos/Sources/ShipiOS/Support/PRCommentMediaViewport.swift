import AppKit
import SwiftUI

struct PRCommentMediaViewport: NSViewRepresentable {
  let changed: (CGFloat) -> Void
  func makeNSView(context: Context) -> Reader { Reader() }
  func updateNSView(_ view: Reader, context: Context) { view.changed = changed; view.report() }
  static func dismantleNSView(_ view: Reader, coordinator: ()) { view.detach(); view.changed = nil }
  final class Reader: NSView {
    var changed: ((CGFloat) -> Void)?
    private var observer: NSObjectProtocol?
    private var lastHeight: CGFloat?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow(); detach(); lastHeight = nil
      if let window {
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
          object: window, queue: .main) { [weak self] _ in self?.report() }
      }
      report()
    }
    func detach() { if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil }
    func report() {
      guard let height = window?.contentLayoutRect.height, height.isFinite, height > 0, height != lastHeight else { return }
      lastHeight = height
      DispatchQueue.main.async { [weak self] in
        guard let self, self.window?.contentLayoutRect.height == height else { return }
        self.changed?(height)
      }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
  }
}

struct PRCommentMediaImageView: NSViewRepresentable {
  let image: NSImage
  let alt: String
  let title: String?
  func makeNSView(context: Context) -> Surface { Surface() }
  func updateNSView(_ view: Surface, context: Context) {
    if view.imageView.image !== image { view.imageView.image = image }
    view.imageView.toolTip = title; view.imageView.setAccessibilityLabel(alt)
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: Surface, context: Context) -> CGSize? {
    .init(width: proposal.width ?? image.size.width, height: proposal.height ?? image.size.height)
  }
  static func dismantleNSView(_ view: Surface, coordinator: ()) { view.imageView.image = nil }
  final class Surface: NSView {
    let imageView = NSImageView()
    let imageMask = CAShapeLayer()
    let shadowLayers = [CALayer(), CALayer()]
    private var lastBounds: CGRect?
    override init(frame: NSRect) {
      super.init(frame: frame); wantsLayer = true; layer?.masksToBounds = false
      for (index, shadow) in shadowLayers.enumerated() {
        shadow.shadowColor = NSColor.black.cgColor; shadow.shadowOpacity = 0.1
        shadow.shadowRadius = index == 0 ? 3 : 2; shadow.shadowOffset = .init(width: 0, height: index == 0 ? -4 : -2)
        layer?.addSublayer(shadow)
      }
      imageView.imageScaling = .scaleProportionallyUpOrDown; imageView.imageAlignment = .alignCenter
      imageView.animates = true; imageView.imageFrameStyle = .none; imageView.wantsLayer = true
      imageView.layer?.mask = imageMask; imageView.layer?.masksToBounds = true; addSubview(imageView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
      super.layout(); imageView.frame = bounds
      guard lastBounds != bounds else { return }; lastBounds = bounds
      CATransaction.begin(); CATransaction.setDisableActions(true)
      imageMask.frame = imageView.bounds
      imageMask.path = PRCommentMediaCornerShape(radius: 10).cgPath(in: imageView.bounds)
      for (index, shadow) in shadowLayers.enumerated() {
        let inset = CGFloat(index + 1)
        shadow.frame = bounds
        let rect = CGRect(x: inset, y: inset, width: max(0, bounds.width - inset * 2), height: max(0, bounds.height - inset * 2))
        shadow.shadowPath = PRCommentMediaCornerShape(radius: 10 - inset).cgPath(in: rect)
      }
      CATransaction.commit()
    }
  }
}
