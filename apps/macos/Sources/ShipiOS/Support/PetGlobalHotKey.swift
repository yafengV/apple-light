import Carbon.HIToolbox
import Foundation

@MainActor
final class PetGlobalHotKey {
  private var hotKey: EventHotKeyRef?
  private var handler: EventHandlerRef?
  private let action: () -> Void
  private static let identifier = EventHotKeyID(signature: 0x5348_4950, id: 1) // SHIP

  init(action: @escaping () -> Void) {
    self.action = action
    var event = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let status = InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, context in
        guard let event, let context else { return OSStatus(eventNotHandledErr) }
        var identifier = EventHotKeyID()
        let status = GetEventParameter(
          event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
          nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
        guard status == noErr, identifier.signature == PetGlobalHotKey.identifier.signature,
          identifier.id == PetGlobalHotKey.identifier.id
        else { return OSStatus(eventNotHandledErr) }
        let owner = Unmanaged<PetGlobalHotKey>.fromOpaque(context).takeUnretainedValue()
        Task { @MainActor in owner.action() }
        return noErr
      },
      1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
    if status != noErr { handler = nil }
  }

  func register(_ binding: ShortcutBinding?) throws {
    if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
    guard let binding else { return }
    guard let keyCode = Self.keyCode(binding.key) else {
      throw AgentFailure(message: "宠物全局快捷键不支持这个按键。")
    }
    var modifiers: UInt32 = 0
    if binding.command { modifiers |= UInt32(cmdKey) }
    if binding.control { modifiers |= UInt32(controlKey) }
    if binding.option { modifiers |= UInt32(optionKey) }
    if binding.shift { modifiers |= UInt32(shiftKey) }
    let status = RegisterEventHotKey(
      keyCode, modifiers, Self.identifier, GetApplicationEventTarget(), 0, &hotKey)
    guard status == noErr else {
      hotKey = nil
      throw AgentFailure(message: "无法注册宠物全局快捷键，可能已被其他应用占用。")
    }
  }

  deinit {
    if let hotKey { UnregisterEventHotKey(hotKey) }
    if let handler { RemoveEventHandler(handler) }
  }

  private static func keyCode(_ key: String) -> UInt32? {
    let codes: [String: Int] = [
      "a": kVK_ANSI_A, "s": kVK_ANSI_S, "d": kVK_ANSI_D, "f": kVK_ANSI_F,
      "h": kVK_ANSI_H, "g": kVK_ANSI_G, "z": kVK_ANSI_Z, "x": kVK_ANSI_X,
      "c": kVK_ANSI_C, "v": kVK_ANSI_V, "b": kVK_ANSI_B, "q": kVK_ANSI_Q,
      "w": kVK_ANSI_W, "e": kVK_ANSI_E, "r": kVK_ANSI_R, "y": kVK_ANSI_Y,
      "t": kVK_ANSI_T, "o": kVK_ANSI_O, "u": kVK_ANSI_U, "i": kVK_ANSI_I,
      "p": kVK_ANSI_P, "l": kVK_ANSI_L, "j": kVK_ANSI_J, "k": kVK_ANSI_K,
      "n": kVK_ANSI_N, "m": kVK_ANSI_M,
      "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
      "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
      "8": kVK_ANSI_8, "9": kVK_ANSI_9,
      "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket,
      "]": kVK_ANSI_RightBracket, "\\": kVK_ANSI_Backslash, ";": kVK_ANSI_Semicolon,
      "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period,
      "/": kVK_ANSI_Slash, "`": kVK_ANSI_Grave,
      "space": kVK_Space, "↵": kVK_Return,
      "⇥": kVK_Tab, "⎋": kVK_Escape, "←": kVK_LeftArrow, "→": kVK_RightArrow,
      "↓": kVK_DownArrow, "↑": kVK_UpArrow,
    ]
    return codes[key].map(UInt32.init)
  }
}
