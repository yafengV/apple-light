import Foundation
import Observation

enum AppearanceAccountAccent: String, CaseIterable, Sendable {
  case `default`, blue, green, yellow, pink, orange, purple, black
  func title(dark: Bool) -> String {
    switch self {
    case .default: "默认"
    case .blue: "蓝色"
    case .green: "绿色"
    case .yellow: "黄色"
    case .pink: "粉色"
    case .orange: "橙色"
    case .purple: "紫色"
    case .black: dark ? "白色" : "黑色"
    }
  }
  func messageKey(dark: Bool) -> String { "settings.appearance.chatGptAccent." + (self == .black && dark ? "white" : rawValue) }
  func swatch(dark: Bool) -> AppearanceRGBA {
    let hex: String
    switch self {
    case .default, .black: hex = dark ? "#ffffff" : "#000000"
    case .blue: hex = dark ? "#2c67c5" : "#3a83f7"
    case .green: hex = dark ? "#48a04c" : "#53b559"
    case .yellow: hex = dark ? "#d9a337" : "#f6c543"
    case .pink: hex = "#f077af"
    case .orange: hex = dark ? "#d25e28" : "#ee7c37"
    case .purple: hex = dark ? "#7849d1" : "#8952ee"
    }
    return .init(hex: hex)
  }
}

struct AppearanceAccentSelection {
  let source: String?
  var accountAccent: AppearanceAccountAccent? = nil
  let dark: Bool
  var selectedID: String { source == "chatgpt" ? (accountAccent ?? .default).rawValue : "custom" }
  var isCustom: Bool { selectedID == "custom" }
  var title: String { isCustom ? "自定义" : (accountAccent ?? .default).title(dark: dark) }
  var messageKey: String { isCustom ? "settings.appearance.chatGptAccent.custom" : (accountAccent ?? .default).messageKey(dark: dark) }
  var customLabel: String { dark ? "深色自定义强调色" : "浅色模式下的自定义强调色" }
}

@MainActor @Observable final class AppearanceAccentMenuState: SettingsPopupMenuState {
  struct Option: Identifiable {
    let id: String
    let title: String
    let swatch: AppearanceRGBA?
    let enabled: Bool
  }
  private(set) var presented = false
  var highlightedID: String?
  private(set) var dark = false
  private var search = ""
  private var lastTypedAt: TimeInterval?
  var options: [Option] {
    // Independent API configuration provides no ChatGPT account settings.
    // Keep account choices visible and disabled, as in the reference's null-account branch.
    AppearanceAccountAccent.allCases.map { .init(id: $0.rawValue, title: $0.title(dark: dark), swatch: $0.swatch(dark: dark), enabled: false) }
      + [.init(id: "custom", title: "自定义", swatch: nil, enabled: true)]
  }
  static func rowHeight(fontSize: CGFloat) -> CGFloat { fontSize * (1.25 / 0.875) + 10 }
  func height(fontSize: CGFloat) -> CGFloat { CGFloat(options.count) * Self.rowHeight(fontSize: fontSize) + 8 }
  func open(dark: Bool, keyboard: Bool, store: WorkspaceStore) {
    guard store.libraryLoaded, !store.restoringLibrary else { return }
    self.dark = dark; presented = true; highlightedID = keyboard ? options.first(where: \.enabled)?.id : nil
    search = ""; lastTypedAt = nil
  }
  func dismiss() { presented = false; highlightedID = nil; search = ""; lastTypedAt = nil }
  func move(_ delta: Int) {
    let enabled = options.filter(\.enabled)
    guard presented, !enabled.isEmpty else { return }
    let index = highlightedID.flatMap { id in enabled.firstIndex { $0.id == id } }
    highlightedID = enabled[index.map { max(0, min(enabled.count - 1, $0 + delta)) } ?? (delta < 0 ? enabled.count - 1 : 0)].id
  }
  func edge(last: Bool) { guard presented else { return }; highlightedID = last ? options.last(where: \.enabled)?.id : options.first(where: \.enabled)?.id }
  func hover(_ id: String?) { guard presented, id == nil || options.contains(where: { $0.id == id && $0.enabled }) else { return }; highlightedID = id }
  func type(_ character: String, now: TimeInterval) {
    guard presented else { return }
    if lastTypedAt.map({ now - $0 >= 1 }) != false { search = "" }
    search += character; lastTypedAt = now
    let chars = Array(search)
    let pattern = chars.count > 1 && chars.allSatisfy({ $0 == chars.first }) ? String(chars[0]) : search
    let enabled = options.filter(\.enabled)
    let start = highlightedID.flatMap { id in enabled.firstIndex { $0.id == id } } ?? 0
    for index in 0..<enabled.count {
      let candidate = enabled[(start + index) % enabled.count]
      if !(pattern.utf16.count == 1 && candidate.id == highlightedID), candidate.title.lowercased().hasPrefix(pattern.lowercased()) {
        highlightedID = candidate.id; break
      }
    }
  }
  func space(now: TimeInterval) -> Bool {
    guard presented else { return false }
    if lastTypedAt.map({ now - $0 < 1 }) == true, !search.isEmpty { type(" ", now: now); return false }; return true
  }
  @discardableResult func choose(_ id: String, store: WorkspaceStore) -> Bool {
    guard presented, store.libraryLoaded, !store.restoringLibrary, options.contains(where: { $0.id == id && $0.enabled }) else { return false }
    let currentAccent = store.appearance.themeShare(dark: dark).theme.accent
    _ = store.setAppearanceColor(currentAccent, key: \.accent, dark: dark)
    dismiss(); return true
  }
}
