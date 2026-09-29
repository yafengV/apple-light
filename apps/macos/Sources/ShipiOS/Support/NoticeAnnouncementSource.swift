import AppKit
import SwiftUI

/// The SwiftUI stack owns notice values. This noninteractive bridge only posts
/// polite accessibility announcements for additions and text changes.
struct NoticeAnnouncementSource: NSViewRepresentable {
  let packets: [NoticeAnnouncement]
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> Source {
    let source = Source()
    source.setAccessibilityElement(false)
    context.coordinator.attach(source)
    return source
  }
  func updateNSView(_ source: Source, context: Context) { context.coordinator.stage(packets) }
  static func dismantleNSView(_ source: Source, coordinator: Coordinator) { coordinator.stop() }

  final class Source: NSView {
    weak var coordinator: Coordinator?
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow(); coordinator?.watchWindow()
    }
  }

  @MainActor final class Coordinator {
    typealias Announce = @MainActor (String, NSAccessibilityPriorityLevel) -> Void
    private weak var source: Source?
    private var pending: [NoticeAnnouncement] = []
    private var changes = NoticeAnnouncementChanges()
    private var observers: [NSObjectProtocol] = []
    private var active = true
    private var queued = false
    private let announce: Announce
    init(announce: @escaping Announce = { text, priority in
      guard let application = NSApp else { return }
      NSAccessibility.post(element: application, notification: .announcementRequested,
        userInfo: [.announcement: text, .priority: priority.rawValue])
    }) { self.announce = announce }

    func attach(_ source: Source) {
      self.source = source; source.coordinator = self; watchWindow()
    }
    func stage(_ packets: [NoticeAnnouncement]) { pending = packets; schedule() }
    func watchWindow() {
      removeObservers()
      guard active, let window = source?.window else { return }
      for name in [NSWindow.didBecomeKeyNotification, NSWindow.didExposeNotification, NSWindow.didDeminiaturizeNotification] {
        observe(name, object: window)
      }
      observe(NSApplication.didUnhideNotification, object: NSApp)
      schedule()
    }
    private func observe(_ name: Notification.Name, object: Any?) {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.schedule() }
      })
    }
    private func schedule() {
      guard active, !queued else { return }
      queued = true
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }; self.queued = false; self.flush()
      }
    }
    func flush() {
      guard active, let source, let window = source.window, window.isVisible,
        !window.isMiniaturized, !source.isHiddenOrHasHiddenAncestor, !NSApp.isHidden else { return }
      for text in changes.receive(pending) { announce(text, .low) }
    }
    func stop() {
      active = false; pending = []; removeObservers()
      source?.coordinator = nil; source = nil
    }
    private func removeObservers() {
      observers.forEach(NotificationCenter.default.removeObserver); observers = []
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
  }
}
