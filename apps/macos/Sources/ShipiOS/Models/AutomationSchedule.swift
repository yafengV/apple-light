import Foundation

enum AutomationCadence: String, Codable, CaseIterable, Identifiable {
  case hourly, daily, weekly
  var id: String { rawValue }
  var title: String {
    switch self {
    case .hourly: "每小时"
    case .daily: "每天"
    case .weekly: "每周"
    }
  }
}

struct ShipAutomation: Codable, Identifiable, Equatable {
  var id = UUID()
  var name = ""
  var prompt = ""
  var project = ""
  var cadence = AutomationCadence.daily
  var hour = 9
  var minute = 0
  /// Calendar weekday: 1 = Sunday, 7 = Saturday.
  var weekday = 2
  var enabled = true
  var nextRun: Date = .now
  var lastRun: Date?
  var taskID: String?
  var lastRunID: String?
  var reviewedRunID: String?

  var needsReview: Bool { lastRunID != nil && reviewedRunID != lastRunID }

  func nextDate(after date: Date, calendar: Calendar = .current) -> Date {
    switch cadence {
    case .hourly:
      var components = calendar.dateComponents([.year, .month, .day, .hour], from: date)
      components.minute = minute
      components.second = 0
      let candidate = calendar.date(from: components) ?? date
      return candidate > date ? candidate : calendar.date(byAdding: .hour, value: 1, to: candidate) ?? date.addingTimeInterval(3600)
    case .daily:
      return calendar.nextDate(
        after: date, matching: DateComponents(hour: hour, minute: minute),
        matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
        ?? date.addingTimeInterval(86_400)
    case .weekly:
      return calendar.nextDate(
        after: date, matching: DateComponents(hour: hour, minute: minute, weekday: weekday),
        matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
        ?? date.addingTimeInterval(604_800)
    }
  }

  var scheduleLabel: String {
    let time = String(format: "%02d:%02d", hour, minute)
    switch cadence {
    case .hourly: return "每小时的 \(String(format: "%02d", minute)) 分"
    case .daily: return "每天 \(time)"
    case .weekly:
      let symbols = Calendar.current.shortWeekdaySymbols
      let index = min(max(weekday - 1, 0), symbols.count - 1)
      return "每周\(symbols[index]) \(time)"
    }
  }
}

struct AutomationPreferences: Codable, Equatable {
  var items: [ShipAutomation] = []
}

enum AutomationStorage {
  static func load(root: URL) throws -> AutomationPreferences {
    let url = root.appendingPathComponent("automations.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return AutomationPreferences() }
    let value = try JSONDecoder().decode(AutomationPreferences.self, from: Data(contentsOf: url))
    try validate(value)
    return value
  }

  static func save(_ value: AutomationPreferences, root: URL) throws {
    try validate(value)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("automations.json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(value).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  static func validate(_ value: AutomationPreferences) throws {
    guard Set(value.items.map(\.id)).count == value.items.count else {
      throw AgentFailure(message: "自动化数据包含重复标识。")
    }
    for item in value.items {
      guard !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        item.name.utf8.count <= 120,
        !item.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        item.prompt.utf8.count <= 20_000,
        (0...23).contains(item.hour), (0...59).contains(item.minute),
        (1...7).contains(item.weekday)
      else { throw AgentFailure(message: "自动化名称、指令或日程无效。") }
    }
  }
}
