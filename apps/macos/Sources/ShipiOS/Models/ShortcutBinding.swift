import AppKit
import SwiftUI

struct ShortcutBinding: Codable, Equatable, Hashable {
  let key: String
  let command: Bool
  let control: Bool
  let option: Bool
  let shift: Bool

  init(_ display: String) {
    command = display.contains("⌘")
    control = display.contains("⌃")
    option = display.contains("⌥")
    shift = display.contains("⇧")
    key = display.filter { !"⌘⌃⌥⇧".contains($0) }.lowercased()
  }

  init?(event: NSEvent) {
    let flags = event.modifierFlags
    command = flags.contains(.command)
    control = flags.contains(.control)
    option = flags.contains(.option)
    shift = flags.contains(.shift)
    switch event.keyCode {
    case 36: key = "↵"
    case 48: key = "⇥"
    case 49: key = "space"
    case 53: key = "⎋"
    case 123: key = "←"
    case 124: key = "→"
    case 125: key = "↓"
    case 126: key = "↑"
    default:
      guard let characters = event.characters(byApplyingModifiers: []),
        characters.count == 1,
        characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
      else { return nil }
      key = characters.lowercased()
    }
  }

  var display: String {
    (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "")
      + (command ? "⌘" : "") + (key == "space" ? "Space" : key.uppercased())
  }
  var keyboardShortcut: KeyboardShortcut {
    let equivalent: KeyEquivalent
    switch key {
    case "↵": equivalent = .return
    case "⇥": equivalent = .tab
    case "space": equivalent = .space
    case "⎋": equivalent = .escape
    case "←": equivalent = .leftArrow
    case "→": equivalent = .rightArrow
    case "↓": equivalent = .downArrow
    case "↑": equivalent = .upArrow
    default: equivalent = KeyEquivalent(key.first ?? " ")
    }
    var modifiers: EventModifiers = []
    if command { modifiers.insert(.command) }
    if control { modifiers.insert(.control) }
    if option { modifiers.insert(.option) }
    if shift { modifiers.insert(.shift) }
    return KeyboardShortcut(equivalent, modifiers: modifiers)
  }
  var validationMessage: String? {
    guard command || control || (key == "⎋" && shift && !option)
      || (key == "space" && option && !shift)
    else {
      return "请包含 Command 或 Control，避免与文字输入冲突。"
    }
    guard key == "space" || key.count == 1 else { return "不支持这个按键。" }
    if command && !control && !option && !shift
      && ["q", "w", "h", "m", "c", "v", "x", "a", "z"].contains(key)
    {
      return "此快捷键由 macOS 的窗口或文本编辑命令使用。"
    }
    if command && !control && !option && shift && key == "z" {
      return "此快捷键由文本编辑的重做命令使用。"
    }
    return nil
  }

  func validationMessage(for commandID: String) -> String? {
    if ["approval-approve", "approval-decline"].contains(commandID),
      !command && !control && !option && !shift, ["↵", "⎋"].contains(key) { return nil }
    return validationMessage
  }
}
