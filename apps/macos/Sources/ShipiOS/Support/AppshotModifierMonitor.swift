import AppKit

/// A modifier-only shortcut cannot be registered through Carbon hot keys.
/// Global monitoring requires macOS Accessibility permission; the local monitor
/// keeps the same shortcut usable while ShipiOS itself is frontmost.
@MainActor final class AppshotModifierMonitor {
  private var globalMonitor: Any?
  private var localMonitor: Any?
  private var chord = AppshotCommandChord()
  private let onTrigger: () -> Void

  init(onTrigger: @escaping () -> Void) {
    self.onTrigger = onTrigger
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) {
      [weak self] event in
      let type = event.type
      let code = event.keyCode
      let command = event.modifierFlags.contains(.command)
      let timestamp = event.timestamp
      Task { @MainActor [weak self] in
        self?.consume(type: type, keyCode: code, commandDown: command, timestamp: timestamp)
      }
    }
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) {
      [weak self] event in
      let type = event.type
      let code = event.keyCode
      let command = event.modifierFlags.contains(.command)
      let timestamp = event.timestamp
      Task { @MainActor [weak self] in
        self?.consume(type: type, keyCode: code, commandDown: command, timestamp: timestamp)
      }
      return event
    }
  }

  private func consume(type: NSEvent.EventType, keyCode: UInt16,
    commandDown: Bool, timestamp: TimeInterval) {
    if type == .keyDown { chord.reset(); return }
    guard type == .flagsChanged else { return }
    if chord.flagsChanged(keyCode: keyCode, commandDown: commandDown, at: timestamp) {
      onTrigger()
    }
  }

  deinit {
    if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    if let localMonitor { NSEvent.removeMonitor(localMonitor) }
  }
}
