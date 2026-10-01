import AppKit
import ApplicationServices

@MainActor final class AppshotGlobalMonitorRegistration {
  private var monitor: Any?
  private let register: () -> Any?
  private let remove: (Any) -> Void

  init(register: @escaping () -> Any?, remove: @escaping (Any) -> Void) {
    self.register = register
    self.remove = remove
  }

  var isRegistered: Bool { monitor != nil }

  @discardableResult func refresh(trusted: Bool) -> Bool {
    let wasRegistered = isRegistered
    if !trusted { stop() }
    else if monitor == nil { monitor = register() }
    return wasRegistered != isRegistered
  }

  func stop() {
    if let monitor { remove(monitor) }
    monitor = nil
  }
}

/// A modifier-only shortcut cannot be registered through Carbon hot keys.
/// Global monitoring requires macOS Accessibility permission; the local monitor
/// keeps the same shortcut usable while ShipiOS itself is frontmost.
@MainActor final class AppshotModifierMonitor {
  private var globalRegistration: AppshotGlobalMonitorRegistration?
  private var localMonitor: Any?
  private var activationObserver: NSObjectProtocol?
  private var chord = AppshotCommandChord()
  private let hotkey: () -> AppshotHotkey
  private let onTrigger: () -> Void
  private let onRegistrationState: (Bool, Bool) -> Void

  init(hotkey: @escaping () -> AppshotHotkey, onTrigger: @escaping () -> Void,
    onRegistrationState: @escaping (Bool, Bool) -> Void = { _, _ in }) {
    self.hotkey = hotkey
    self.onTrigger = onTrigger
    self.onRegistrationState = onRegistrationState
    globalRegistration = AppshotGlobalMonitorRegistration(register: { [weak self] in
      NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) {
        [weak self] event in
        let type = event.type
        let code = event.keyCode
        let flags = event.modifierFlags.rawValue
        let timestamp = event.timestamp
        Task { @MainActor [weak self] in
          self?.consume(type: type, keyCode: code, flagsRaw: flags, timestamp: timestamp)
        }
      }
    }, remove: { NSEvent.removeMonitor($0) })
    refreshGlobalMonitor()
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
    activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in self?.refreshGlobalMonitor() }
    }
  }

  func refreshGlobalMonitor() {
    let shouldRegister = hotkey() != .none && AXIsProcessTrusted()
    if globalRegistration?.refresh(trusted: shouldRegister) == true {
      chord.reset()
    }
    onRegistrationState(shouldRegister, globalRegistration?.isRegistered == true)
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
    if let activationObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
    }
    let registration = globalRegistration
    Task { @MainActor in registration?.stop() }
    if let localMonitor { NSEvent.removeMonitor(localMonitor) }
  }
}
