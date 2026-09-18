import AppKit
import SwiftUI

/// macOS 14 has no SwiftUI scroll phase API. Observe the enclosing native scroll
/// view without replacing SwiftUI's content, selection, or lazy rendering.
struct ConversationScrollObserver: NSViewRepresentable {
  enum Event {
    case geometry(ConversationScrollMetrics)
    case began
    case ended(ConversationScrollMetrics)
  }
  var receive: (Event) -> Void

  func makeNSView(context: Context) -> Probe { Probe() }
  func updateNSView(_ view: Probe, context: Context) {
    view.receive = receive
    view.scheduleAttach()
  }
  static func dismantleNSView(_ view: Probe, coordinator: ()) { view.deactivate() }

  final class Probe: NSView {
    var receive: ((Event) -> Void)?
    private weak var observed: NSScrollView?
    private weak var document: NSView?
    private var tokens: [NSObjectProtocol] = []
    private var generation = UUID()
    private var attachScheduled = false
    private var disposed = false
    private var originalClipBoundsNotifications = false
    private var originalClipFrameNotifications = false
    private var originalDocumentFrameNotifications = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if window == nil { stop() } else { scheduleAttach() }
    }
    override func viewDidMoveToSuperview() {
      super.viewDidMoveToSuperview()
      scheduleAttach()
    }
    override func layout() {
      super.layout()
      scheduleAttach()
    }
    func scheduleAttach() {
      guard !disposed, !attachScheduled else { return }
      attachScheduled = true
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        attachScheduled = false
        attach()
      }
    }
    private func attach() {
      guard !disposed, window != nil, let scroll = enclosingScrollView,
        let content = scroll.documentView
      else { return }
      guard observed !== scroll || document !== content else { return }
      stop()
      observed = scroll
      document = content
      originalClipBoundsNotifications = scroll.contentView.postsBoundsChangedNotifications
      originalClipFrameNotifications = scroll.contentView.postsFrameChangedNotifications
      originalDocumentFrameNotifications = content.postsFrameChangedNotifications
      scroll.contentView.postsBoundsChangedNotifications = true
      scroll.contentView.postsFrameChangedNotifications = true
      content.postsFrameChangedNotifications = true
      observe(NSView.boundsDidChangeNotification, object: scroll.contentView) { view in
        view.publishGeometry()
      }
      observe(NSView.frameDidChangeNotification, object: scroll.contentView) { view in
        view.publishGeometry()
      }
      observe(NSView.frameDidChangeNotification, object: content) { view in view.publishGeometry() }
      observe(NSScrollView.willStartLiveScrollNotification, object: scroll) { view in
        view.publish(.began)
      }
      observe(NSScrollView.didEndLiveScrollNotification, object: scroll) { view in
        if let metrics = view.metrics { view.publish(.ended(metrics)) }
      }
      publishGeometry()
    }
    private var metrics: ConversationScrollMetrics? {
      guard let observed, let document else { return nil }
      let visible = observed.contentView.bounds
      let height = document.bounds.height
      let offset = document.isFlipped ? visible.minY : height - visible.maxY
      return ConversationScrollMetrics(
        offset: Double(offset), contentHeight: Double(height),
        viewportHeight: Double(visible.height))
    }
    private func observe(
      _ name: Notification.Name, object: AnyObject, action: @escaping (Probe) -> Void
    ) {
      tokens.append(
        NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) {
          [weak self] _ in
          MainActor.assumeIsolated { if let self { action(self) } }
        })
    }
    private func publishGeometry() {
      if let metrics { publish(.geometry(metrics)) }
    }
    private func publish(_ event: Event) {
      let token = generation
      // SwiftUI state must not change inside an AppKit layout/update pass.
      DispatchQueue.main.async { [weak self] in
        guard let self, generation == token else { return }
        receive?(event)
      }
    }
    func stop() {
      generation = UUID()
      tokens.forEach(NotificationCenter.default.removeObserver)
      tokens.removeAll()
      observed?.contentView.postsBoundsChangedNotifications = originalClipBoundsNotifications
      observed?.contentView.postsFrameChangedNotifications = originalClipFrameNotifications
      document?.postsFrameChangedNotifications = originalDocumentFrameNotifications
      observed = nil
      document = nil
    }
    func deactivate() {
      disposed = true
      receive = nil
      stop()
    }
    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
  }
}
