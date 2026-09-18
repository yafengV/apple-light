import AppKit

enum ExternalBrowserLinkShortcut: String, Codable, CaseIterable {
  case unassigned, primary, alt
  case primaryShift = "primary-shift"

  var title: String {
    switch self {
    case .unassigned: "未设置"
    case .primary: "⌘点按"
    case .alt: "⌥点按"
    case .primaryShift: "⇧⌘点按"
    }
  }

  func matches(_ click: WebLinkClick?) -> Bool {
    guard let click, click.button == 0 else { return false }
    let flags = click.modifiers.intersection([.command, .control, .option, .shift])
    switch self {
    case .unassigned: return false
    case .primary: return flags == .command
    case .alt: return flags == .option
    case .primaryShift: return flags == [.command, .shift]
    }
  }
}

/// Capture at link activation, before any task or project switch suspends.
struct WebLinkClick {
  let modifiers: NSEvent.ModifierFlags
  var button = 0

  init(modifiers: NSEvent.ModifierFlags, button: Int = 0) {
    self.modifiers = modifiers
    self.button = button
  }

  init?(event: NSEvent?) {
    guard let event, [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
      .otherMouseDown, .otherMouseUp].contains(event.type) else { return nil }
    modifiers = event.modifierFlags
    // DOM: left=0, middle=1, right=2. AppKit swaps middle and right.
    button = event.buttonNumber == 1 ? 2 : event.buttonNumber == 2 ? 1 : event.buttonNumber
  }
}
