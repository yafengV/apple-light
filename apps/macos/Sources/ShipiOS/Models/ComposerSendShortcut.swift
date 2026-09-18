import Foundation

enum ComposerSendShortcut: String, CaseIterable, Identifiable {
  case enter
  case commandEnter
  case commandEnterForMultiline

  var id: String { rawValue }

  var title: String {
    switch self {
    case .enter: "Enter"
    case .commandEnter: "始终 ⌘Enter"
    case .commandEnterForMultiline: "多行消息使用 ⌘Enter"
    }
  }

  var explanation: String {
    switch self {
    case .enter: "Enter 发送，Shift + Enter 换行。"
    case .commandEnter: "Enter 换行，⌘Enter 发送。"
    case .commandEnterForMultiline: "单行消息按 Enter 发送；消息包含换行后，按 ⌘Enter 发送。"
    }
  }

  func sendsOnPlainReturn(_ text: String) -> Bool {
    switch self {
    case .enter: true
    case .commandEnter: false
    case .commandEnterForMultiline: !text.contains("\n")
    }
  }

  static func stored(defaults: UserDefaults = .standard) -> ComposerSendShortcut {
    if let raw = defaults.string(forKey: storageKey), let value = Self(rawValue: raw) {
      return value
    }
    return defaults.bool(forKey: legacyKey) ? .enter : .commandEnter
  }

  static func migrate(defaults: UserDefaults = .standard) {
    guard defaults.object(forKey: storageKey) == nil else { return }
    defaults.set(stored(defaults: defaults).rawValue, forKey: storageKey)
  }

  static let storageKey = "shipios.sendShortcutMode"
  static let legacyKey = "shipios.sendWithEnter"
}
