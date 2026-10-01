import AppKit
import ApplicationServices

/// AppKit's global event monitor observes bare modifiers in other apps when AX access is granted.
@MainActor final class VoiceBareModifierMonitor {
  private var globalMonitor: Any?
  private var localMonitor: Any?
  private var activationObserver: NSObjectProtocol?
  private var state = VoiceBareModifierState()
  private var lastHold: ShortcutBinding?
  private var lastToggle: ShortcutBinding?
  private var lastVoiceChat: ShortcutBinding?
  private let bindings: () -> (hold: ShortcutBinding?, toggle: ShortcutBinding?, voiceChat: ShortcutBinding?)
  private let onAction: (VoiceBareModifierState.Action) -> Void
  private let onRegistrationError: (String?) -> Void

  init(bindings: @escaping () -> (hold: ShortcutBinding?, toggle: ShortcutBinding?,
    voiceChat: ShortcutBinding?),
    onAction: @escaping (VoiceBareModifierState.Action) -> Void,
    onRegistrationError: @escaping (String?) -> Void) {
    self.bindings = bindings
    self.onAction = onAction
    self.onRegistrationError = onRegistrationError
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) {
      [weak self] event in
      self?.consume(type: event.type, flags: event.modifierFlags)
      return event
    }
    activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in self?.refresh() }
    }
  }

  func refresh() {
    let selected = bindings()
    let bareHold = selected.hold?.isBareModifier == true ? selected.hold : nil
    let bareToggle = selected.toggle?.isBareModifier == true ? selected.toggle : nil
    let bareVoiceChat = selected.voiceChat?.isBareModifier == true ? selected.voiceChat : nil
    if bareHold != lastHold || bareToggle != lastToggle || bareVoiceChat != lastVoiceChat {
      if bareHold != lastHold {
        state.reset(currentFlags: NSEvent.modifierFlags).forEach(onAction)
      } else {
        state.reconfigureSecondary(currentFlags: NSEvent.modifierFlags)
      }
      lastHold = bareHold
      lastToggle = bareToggle
      lastVoiceChat = bareVoiceChat
    }
    let enabled = bareHold != nil || bareToggle != nil || bareVoiceChat != nil
    let trusted = AXIsProcessTrusted()
    if !enabled || !trusted {
      if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
      globalMonitor = nil
    } else if globalMonitor == nil {
      globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) {
        [weak self] event in
        let type = event.type
        let flags = event.modifierFlags
        Task { @MainActor [weak self] in self?.consume(type: type, flags: flags) }
      }
    }
    let error = enabled && (!trusted || globalMonitor == nil)
      ? "全局语音修饰键需要在系统设置中允许 ShipiOS 使用辅助功能。" : nil
    onRegistrationError(error)
  }

  private func consume(type: NSEvent.EventType, flags: NSEvent.ModifierFlags) {
    let selected = bindings()
    let actions = type == .keyDown ? state.keyDown(currentFlags: flags)
      : state.flagsChanged(flags, hold: selected.hold, toggle: selected.toggle,
        voiceChat: selected.voiceChat)
    actions.forEach(onAction)
  }

  deinit {
    if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    if let activationObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
    }
  }
}
