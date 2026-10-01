import AppKit

/// A modifier-only shortcut cannot be registered through Carbon hot keys.
/// Global monitoring requires macOS Accessibility permission; the local monitor
/// keeps the same shortcut usable while ShipiOS itself is frontmost.
@MainActor final class AppshotModifierMonitor {
  private var globalMonitor: Any?
  private var localMonitor: Any?
  private var chord = AppshotCommandChord()
  private let hotkey: () -> AppshotHotkey
  private let onTrigger: () -> Void

  init(hotkey: @escaping () -> AppshotHotkey, onTrigger: @escaping () -> Void) {
    self.hotkey = hotkey
    self.onTrigger = onTrigger
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) {
      [weak self] event in
      let type = event.type
      let code = event.keyCode
      let flags = event.modifierFlags.rawValue
      let timestamp = event.timestamp
      Task { @MainActor [weak self] in
        self?.consume(type: type, keyCode: code, flagsRaw: flags, timestamp: timestamp)
      }
    }
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) {
      [weak self] event in
      let type = event.type
      let code = event.keyCode
      let flags = event.modifierFlags.rawValue
      let timestamp = event.timestamp
      Task { @MainActor [weak self] in
        self?.consume(type: type, keyCode: code, flagsRaw: flags, timestamp: timestamp)
      }
      return event
    }
  }

  private func consume(type: NSEvent.EventType, keyCode: UInt16,
    flagsRaw: UInt, timestamp: TimeInterval) {
    if type == .keyDown { chord.reset(); return }
    guard type == .flagsChanged else { return }
    let selected = hotkey()
    let flags = NSEvent.ModifierFlags(rawValue: flagsRaw)
    let modifiers = flags.intersection([.command, .option, .shift, .control])
    let required: NSEvent.ModifierFlags
    switch selected {
    case .doubleCommand: required = .command
    case .doubleOption: required = .option
    case .doubleShift: required = .shift
    case .none: required = []
    }
    if chord.flagsChanged(keyCode: keyCode, modifierDown: modifiers == required,
      hotkey: selected, at: timestamp) {
      onTrigger()
    }
  }

  deinit {
    if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    if let localMonitor { NSEvent.removeMonitor(localMonitor) }
  }
}
