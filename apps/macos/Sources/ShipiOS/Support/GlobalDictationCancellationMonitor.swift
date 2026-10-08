import AppKit
import Observation

/// Listen only for the lifetime of one global recording. Each native callback
/// retains that recording's token, including callbacks already queued at teardown.
@MainActor final class GlobalDictationCancellationMonitor {
  struct EventMonitoring {
    var local: (NSEvent.EventTypeMask, @escaping (NSEvent) -> NSEvent?) -> Any?
    var global: (NSEvent.EventTypeMask, @escaping (NSEvent) -> Void) -> Any?
    var remove: (Any) -> Void

    static let system = EventMonitoring(
      local: { NSEvent.addLocalMonitorForEvents(matching: $0, handler: $1) },
      global: { NSEvent.addGlobalMonitorForEvents(matching: $0, handler: $1) },
      remove: { NSEvent.removeMonitor($0) })
  }

  private struct KeyPress {
    let escape: Bool
    let repeated: Bool
    init(_ event: NSEvent) {
      escape = event.type == .keyDown && event.keyCode == 53
      repeated = event.isARepeat
    }
  }

  private let activeTarget: () -> String?
  private let isCapturingShortcut: () -> Bool
  private let onCancel: (String) -> Void
  private let events: EventMonitoring
  private var localMonitor: Any?
  private var globalMonitor: Any?
  private(set) var token: String?
  private var awaitingStart = false

  init(activeTarget: @escaping () -> String?,
    isCapturingShortcut: @escaping () -> Bool,
    events: EventMonitoring = .system, onCancel: @escaping (String) -> Void) {
    self.activeTarget = activeTarget
    self.isCapturingShortcut = isCapturingShortcut
    self.events = events
    self.onCancel = onCancel
    observeTarget()
  }

  func prepare(token: String) throws {
    stop()
    self.token = token
    awaitingStart = true
    localMonitor = events.local(.keyDown) { [weak self] event in
      self?.consume(KeyPress(event), token: token) == true ? nil : event
    }
    globalMonitor = events.global(.keyDown) { [weak self] event in
      // AppKit invokes both monitors on the main thread. Invalidate recognition
      // now, before an already queued final result can commit its text.
      MainActor.assumeIsolated { _ = self?.consume(KeyPress(event), token: token) }
    }
    guard localMonitor != nil, globalMonitor != nil else {
      stop()
      throw AgentFailure(message: "无法监听全局听写的 Esc 取消按键，请检查辅助功能权限后重试。")
    }
  }

  /// Speech.start sets its target synchronously before its first suspension.
  func willStart(token: String) {
    guard self.token == token else { return }
    awaitingStart = false
  }

  func didResolveStart(token: String) {
    guard self.token == token else { return }
    refresh()
  }

  func end(token: String) {
    guard self.token == token else { return }
    stop()
  }

  func stop() {
    token = nil
    awaitingStart = false
    if let localMonitor { events.remove(localMonitor) }
    if let globalMonitor { events.remove(globalMonitor) }
    localMonitor = nil
    globalMonitor = nil
  }

  private func consume(_ key: KeyPress, token: String) -> Bool {
    guard self.token == token, key.escape, !key.repeated,
      !isCapturingShortcut() else { return false }
    guard awaitingStart || activeTarget() == token else {
      end(token: token)
      return false
    }
    // Modifier keys may still be held by the hold-to-dictate shortcut.
    stop()
    onCancel(token)
    return true
  }

  private func refresh() {
    if let token, !awaitingStart, activeTarget() != token { stop() }
  }

  private func observeTarget() {
    withObservationTracking { _ = activeTarget() } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        self?.refresh()
        self?.observeTarget()
      }
    }
  }

  deinit {
    if let localMonitor { events.remove(localMonitor) }
    if let globalMonitor { events.remove(globalMonitor) }
  }
}
