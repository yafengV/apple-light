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
  var snapshot: ConversationScrollSnapshot? = nil
  var receive: (Event) -> Void

  func makeNSView(context: Context) -> Probe { Probe() }
  func updateNSView(_ view: Probe, context: Context) {
    view.snapshot = snapshot
    view.receive = receive
    view.scheduleAttach()
  }
  static func dismantleNSView(_ view: Probe, coordinator: ()) { view.deactivate() }

  final class Probe: NSView {
    var receive: ((Event) -> Void)?
    var snapshot: ConversationScrollSnapshot? {
      didSet {
        if oldValue?.probe === self { oldValue?.probe = nil }
        snapshot?.probe = self
      }
    }
    private weak var observed: NSScrollView?
    private weak var document: NSView?
    private var tokens: [NSObjectProtocol] = []
    private var generation = UUID()
    private var attachScheduled = false
    private var disposed = false
    private var pendingGeometry: UUID?
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
      snapshot?.probe = self
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
        view.pendingGeometry = nil
        view.publish(.began)
        view.publishGeometry()
      }
      observe(NSScrollView.didEndLiveScrollNotification, object: scroll) { view in
        if let metrics = view.metrics { view.publish(.ended(metrics)) }
      }
      publishGeometry()
    }
    fileprivate var metrics: ConversationScrollMetrics? {
      guard let observed, let document else { return nil }
      let visible = observed.contentView.bounds
      let height = document.bounds.height
      let offset = document.isFlipped ? visible.minY : height - visible.maxY
      return ConversationScrollMetrics(
        offset: Double(offset), contentHeight: Double(height),
        viewportHeight: Double(visible.height))
    }
    fileprivate func restore(offset: Double) -> ConversationScrollMetrics? {
      guard !disposed, offset.isFinite, let observed, let document, let current = metrics,
        current.viewportHeight > 0 else { return nil }
      let clamped = max(0, min(offset, current.contentHeight - current.viewportHeight))
      let y = document.isFlipped ? clamped : current.contentHeight - current.viewportHeight - clamped
      observed.contentView.scroll(to: NSPoint(x: observed.contentView.bounds.minX, y: y))
      observed.reflectScrolledClipView(observed.contentView)
      return metrics
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
      guard pendingGeometry == nil, observed != nil else { return }
      let request = UUID(), token = generation
      pendingGeometry = request
      DispatchQueue.main.async { [weak self] in
        guard let self, generation == token, pendingGeometry == request else { return }
        pendingGeometry = nil
        if let metrics { receive?(.geometry(metrics)) }
      }
    }
    private func publish(_ event: Event) {
      let token = generation
      // SwiftUI state must not change inside an AppKit layout/update pass.
      DispatchQueue.main.async { [weak self] in
        guard let self, generation == token else { return }
        if case .ended = event {
          if let metrics { receive?(.ended(metrics)) }
        } else { receive?(event) }
      }
    }
    func stop() {
      generation = UUID()
      pendingGeometry = nil
      if snapshot?.probe === self { snapshot?.probe = nil }
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

/// Access to the native position before revisions scroll, and a narrow restore
/// operation invoked from the observer's deferred events, outside layout.
@MainActor final class ConversationScrollSnapshot {
  fileprivate weak var probe: ConversationScrollObserver.Probe?
  var metrics: ConversationScrollMetrics? { probe?.metrics }
  func restore(offset: Double) -> ConversationScrollMetrics? { probe?.restore(offset: offset) }
}
