import AppKit
import SwiftUI

/// Keeps the PR document's vertical position when its Code tab is removed and rebuilt.
struct PullRequestCodeScrollPosition: NSViewRepresentable {
  let state: GitHubPRCodeState

  func makeNSView(context: Context) -> Probe { Probe() }
  func updateNSView(_ view: Probe, context: Context) {
    view.state = state
    view.scheduleAttach()
  }
  static func dismantleNSView(_ view: Probe, coordinator: ()) { view.deactivate() }

  @MainActor final class Probe: NSView {
    weak var state: GitHubPRCodeState?
    private weak var observed: NSScrollView?
    private var boundsObserver: NSObjectProtocol?
    private var restoreTask: Task<Void, Never>?
    private var attachScheduled = false
    private var disposed = false
    private var restoring = false
    private var attachedGeneration: UUID?
    private var originalBoundsNotifications = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if window == nil { detach() } else { scheduleAttach() }
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
        self.attachScheduled = false
        self.attach()
      }
    }
    private func attach() {
      guard !disposed, window != nil, let scroll = enclosingScrollView else { return }
      guard observed !== scroll else { return }
      detach()
      observed = scroll
      restoring = true
      attachedGeneration = state?.scrollGeneration
      originalBoundsNotifications = scroll.contentView.postsBoundsChangedNotifications
      scroll.contentView.postsBoundsChangedNotifications = true
      boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
        object: scroll.contentView, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.capture() }
      }
      let desired = CGFloat(max(0, state?.scrollOffset ?? 0))
      if desired == 0 {
        restoring = false
        capture()
        return
      }
      restoreTask = Task { [weak self, weak scroll] in
        guard let self, let scroll else { return }
        for attempt in 0..<8 {
          try? await Task.sleep(for: .milliseconds(50))
          guard !Task.isCancelled, self.observed === scroll,
            self.attachedGeneration == self.state?.scrollGeneration,
            let document = scroll.documentView else { return }
          document.layoutSubtreeIfNeeded()
          let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
          if desired > maximum + 1 && attempt < 7 { continue }
          let position = document.isFlipped ? min(desired, maximum) : max(0, maximum - desired)
          scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: position))
          scroll.reflectScrolledClipView(scroll.contentView)
          self.restoring = false
          self.capture()
          return
        }
      }
    }
    private func capture() {
      guard !restoring, attachedGeneration == state?.scrollGeneration,
        let observed, let document = observed.documentView else { return }
      let visible = observed.contentView.bounds
      let offset = document.isFlipped ? visible.minY : document.bounds.height - visible.maxY
      state?.rememberScrollOffset(Double(offset))
    }
    private func detach() {
      capture()
      restoreTask?.cancel(); restoreTask = nil
      if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
      boundsObserver = nil
      observed?.contentView.postsBoundsChangedNotifications = originalBoundsNotifications
      observed = nil
      restoring = false
      attachedGeneration = nil
    }
    func deactivate() {
      disposed = true
      detach()
      state = nil
    }
    deinit { if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) } }
  }
}
