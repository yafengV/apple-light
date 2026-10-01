import Foundation

enum AppshotDestination: String, Codable, CaseIterable, Identifiable {
  case automatic
  case lastChat
  case newChat

  var id: String { rawValue }
  var title: String {
    switch self {
    case .automatic: "自动"
    case .lastChat: "当前聊天"
    case .newChat: "新聊天"
    }
  }
  var explanation: String {
    switch self {
    case .automatic: "如果当前聊天最近使用过，则使用当前聊天；否则开始新聊天。"
    case .lastChat: "始终使用当前聊天。"
    case .newChat: "始终开始新聊天。"
    }
  }

  func shouldStartNewChat(hasCurrentChat: Bool, focusedRecently: Bool) -> Bool {
    switch self {
    case .automatic: hasCurrentChat && !focusedRecently
    case .lastChat: false
    case .newChat: hasCurrentChat
    }
  }
}

/// NSEvent reports left and right Command as separate flagsChanged key codes.
/// A short overlap avoids firing when a user is merely switching keys.
struct AppshotCommandChord {
  private var leftDown = false
  private var rightDown = false
  private var firstPress: TimeInterval?
  private var fired = false

  mutating func flagsChanged(keyCode: UInt16, commandDown: Bool,
    at time: TimeInterval) -> Bool {
    guard commandDown else {
      reset()
      return false
    }
    switch keyCode {
    case 55: leftDown.toggle()
    case 54: rightDown.toggle()
    default: return false
    }
    if leftDown != rightDown && firstPress == nil { firstPress = time }
    guard leftDown && rightDown && !fired,
      let firstPress, time - firstPress <= 0.5 else { return false }
    fired = true
    return true
  }

  mutating func reset() {
    leftDown = false
    rightDown = false
    firstPress = nil
    fired = false
  }
}
