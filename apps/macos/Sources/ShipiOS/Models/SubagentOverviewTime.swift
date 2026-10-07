import Foundation

enum SubagentOverviewTime {
  static func trailing(for agent: CodexSubagent, now: Date, calendar: Calendar = .current) -> [String] {
    switch agent.overviewStatus {
    case .done:
      guard let stamp = agent.lastAssistantMessageAtMs ?? agent.recencyAtMs,
        let relative = relative(stamp, now: now, calendar: calendar) else { return [] }
      return [relative + " 前"]
    case .waiting, .active:
      var labels = agent.overviewStatus == .waiting ? ["等待中"] : []
      if let start = agent.startedAtMs { labels.append(elapsed(start, now: now)) }
      return labels
    case .hidden: return []
    }
  }

  /// The reference elapsed component uses narrow English units and omits zero
  /// units, including seconds on an exact minute/hour/day boundary.
  static func elapsed(_ start: Int, now: Date) -> String {
    let seconds = Int(min(Double(Int.max / 1000), max(0,
      floor((now.timeIntervalSince1970 * 1000 - Double(start)) / 1000))))
    let parts = [(seconds / 86400, "d"), (seconds / 3600 % 24, "h"),
      (seconds / 60 % 60, "m"), (seconds % 60, "s")]
      .filter { $0.0 > 0 }.map { "\($0.0)\($0.1)" }
    return parts.isEmpty ? "0s" : parts.joined(separator: " ")
  }

  /// Compact relative time uses calendar days after 24 elapsed hours. It rounds
  /// local midnight differences so DST does not move the day/week boundary.
  static func relative(_ stamp: Int, now: Date, calendar: Calendar) -> String? {
    guard stamp >= 0, stamp <= 8_640_000_000_000_000 else { return nil }
    let date = Date(timeIntervalSince1970: Double(stamp) / 1000)
    let minutes = max(1, floor(now.timeIntervalSince(date) / 60))
    if minutes < 60 { return "\(Int(minutes)) 分" }
    let hours = floor(minutes / 60)
    if hours < 24 { return "\(Int(hours)) 小时" }
    let days = max(1, Int((calendar.startOfDay(for: now)
      .timeIntervalSince(calendar.startOfDay(for: date)) / 86400).rounded()))
    if days < 7 { return "\(days) 天" }
    if days < 30 { return "\(days / 7) 周" }
    if days < 365 { return "\(days / 30) 个月" }
    return "\(days / 365) 年"
  }
}
