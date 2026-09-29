import Foundation

enum NoticeTextLayout {
  /// HTML white-space:normal collapses ASCII whitespace in descriptions.
  /// Titles use white-space:pre-wrap and retain their original text.
  static func description(_ text: String) -> String {
    text.split(whereSeparator: { " \t\n\r\u{000C}".contains($0) }).joined(separator: " ")
  }
}

struct NoticeCardColors {
  let foreground: AppearanceRGBA
  let background: AppearanceRGBA
  let border: AppearanceRGBA
  init(level: WorkspaceNotice.Level, appearance: AppearancePreferences) {
    let dark = appearance.isDark, roles = appearance.resolvedColors
    switch level {
    case .pending, .info:
      foreground = roles["textForeground"]; background = roles["elevatedSecondary"]; border = roles["border"]
    case .success:
      foreground = .init(hex: dark ? "#40c977" : "#00a240")
      background = .init(hex: dark ? "#011c0b" : "#edfaf2"); border = foreground.opacity(0.2)
    case .warning:
      foreground = .init(hex: dark ? "#ff8549" : "#e25507")
      background = .init(hex: dark ? "#281105" : "#fff5f0"); border = foreground.opacity(dark ? 0.4 : 0.15)
    case .error:
      foreground = .init(hex: dark ? "#ff6764" : "#e02e2a")
      background = .init(hex: dark ? "#280b0a" : "#fff0f0")
      border = AppearanceRGBA(hex: dark ? "#fa423e" : "#e02e2a").opacity(dark ? 0.4 : 0.15)
    }
  }
}

/// Sonner's top stack: the collapsed layer uses the front toast's height
/// for its transform origin; its contents retain their natural height.
struct NoticeStackLayout {
  let heights: [CGFloat]
  let expanded: Bool
  func scale(_ index: Int) -> CGFloat { expanded || index == 0 ? 1 : 1 - CGFloat(index) * 0.05 }
  func containerHeight(_ index: Int) -> CGFloat { expanded || index == 0 ? heights[index] : heights.first ?? 42 }
  func offset(_ index: Int) -> CGFloat { expanded ? heights.prefix(index).reduce(0, +) + CGFloat(index) * 8 : CGFloat(index) * 8 }
  func visibleExtent(_ count: Int) -> CGFloat {
    (0..<min(count, heights.count)).map { index in
      offset(index) + containerHeight(index) * (1 - scale(index)) / 2 + heights[index] * scale(index)
    }.max() ?? 0
  }
}

struct NoticeAnnouncement: Equatable {
  let generation: UUID
  let title: String
  let description: String?
  init(_ notice: WorkspaceNotice) { generation = notice.generation; title = notice.title; description = notice.description }
  var text: String { [title, description].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n") }
}

struct NoticeAnnouncementChanges {
  private var previous: [UUID: NoticeAnnouncement] = [:]
  mutating func receive(_ packets: [NoticeAnnouncement]) -> [String] {
    let result = packets.reversed().filter { previous[$0.generation] != $0 }.map(\.text).filter { !$0.isEmpty }
    previous = Dictionary(uniqueKeysWithValues: packets.map { ($0.generation, $0) }); return result
  }
}
