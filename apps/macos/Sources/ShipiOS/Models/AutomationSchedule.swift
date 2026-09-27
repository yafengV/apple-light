import Foundation

enum AutomationCadence: String, Codable, CaseIterable, Identifiable {
  case hourly, daily, weekly, custom
  var id: String { rawValue }
  var title: String {
    switch self {
    case .hourly: "每小时"
    case .daily: "每天"
    case .weekly: "每周"
    case .custom: "自定义"
    }
  }
}

struct ShipAutomation: Codable, Identifiable, Equatable {
  var id = UUID()
  var name = ""
  var prompt = ""
  var project = ""
  /// Nil keeps the single-project format used by older saved automations.
  var projects: [String]?
  /// Nil keeps the local execution mode used by older saved automations.
  var execution: NewTaskExecution?
  /// Nil follows the current independent API service setting for each new run.
  var modelID: String?
  /// Nil follows the current setting; an empty string asks the service to use its default.
  var reasoning: String?
  var cadence = AutomationCadence.daily
  var hour = 9
  var minute = 0
  /// Calendar weekday: 1 = Sunday, 7 = Saturday.
  var weekday = 2
  /// Nil preserves schedules written before multi-day selection was available.
  var weekdays: [Int]?
  var customRule: String?
  var scheduleAnchor: Date?
  var enabled = true
  var nextRun: Date = .now
  var lastRun: Date?
  var taskID: String?
  var lastRunID: String?
  var reviewedRunID: String?
  /// Nil decodes legacy schedules, whose only pending run is their latest unreviewed run.
  var pendingRunIDs: [String]?
  /// Persisted before worktree creation so a failed or interrupted preparation can resume.
  var preparingTaskIDs: [String: String]?
  var activeOccurrenceAt: Date?
  var completedProjectsForOccurrence: [String]?

  var unresolvedRunIDs: [String] {
    if let pendingRunIDs { return pendingRunIDs }
    guard let lastRunID, reviewedRunID != lastRunID else { return [] }
    return [lastRunID]
  }
  var needsReview: Bool { !unresolvedRunIDs.isEmpty }
  var selectedWeekdays: [Int] { weekdays ?? [weekday] }
  var selectedProjects: [String] { projects ?? [project] }
  var selectedExecution: NewTaskExecution { execution ?? .local }

  mutating func setProject(_ path: String, selected: Bool) {
    if path.isEmpty {
      guard selected else { return }
      projects = [""]
      project = ""
      return
    }
    var values = Set(selectedProjects.filter { !$0.isEmpty })
    if selected { values.insert(path) } else { values.remove(path) }
    projects = values.isEmpty ? [""] : values.sorted()
    project = projects?.first ?? ""
  }

  mutating func setWeekday(_ day: Int, selected: Bool) {
    var days = Set(selectedWeekdays)
    if selected { days.insert(day) } else { days.remove(day) }
    guard !days.isEmpty else { return }
    weekdays = days.sorted()
    weekday = weekdays?.first ?? weekday
  }

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
      return selectedWeekdays.compactMap { day in
        calendar.nextDate(
          after: date, matching: DateComponents(hour: hour, minute: minute, weekday: day),
          matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
      }.min() ?? date.addingTimeInterval(604_800)
    case .custom:
      guard let customRule, let rule = try? AutomationRecurrenceRule.parse(customRule) else {
        return date.addingTimeInterval(86_400)
      }
      return rule.nextDate(after: date, anchor: scheduleAnchor ?? date, calendar: calendar)
        ?? date.addingTimeInterval(86_400)
    }
  }

  var scheduleLabel: String {
    let time = String(format: "%02d:%02d", hour, minute)
    switch cadence {
    case .hourly: return "每小时的 \(String(format: "%02d", minute)) 分"
    case .daily: return "每天 \(time)"
    case .weekly:
      let symbols = Calendar.current.shortWeekdaySymbols
      let days = selectedWeekdays.map { symbols[min(max($0 - 1, 0), symbols.count - 1)] }
      return "每周\(days.joined(separator: "、")) \(time)"
    case .custom: return "自定义 · \(customRule ?? "")"
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
        (1...7).contains(item.weekday),
        item.weekdays == nil || (item.weekdays?.isEmpty == false
          && item.weekdays == Array(Set(item.weekdays ?? []).sorted())
          && item.weekdays?.allSatisfy { (1...7).contains($0) } == true)
      else { throw AgentFailure(message: "自动化名称、指令或日程无效。") }
      if let projects = item.projects {
        guard !projects.isEmpty, projects == Array(Set(projects).sorted()),
          (projects.count == 1 || !projects.contains("")), item.project == projects.first else {
          throw AgentFailure(message: "自动化项目列表无效。")
        }
      }
      if let preparingTaskIDs = item.preparingTaskIDs,
        !preparingTaskIDs.values.allSatisfy({ UUID(uuidString: $0) != nil }) {
        throw AgentFailure(message: "自动化待准备任务标识无效。")
      }
      if let modelID = item.modelID,
        (modelID.isEmpty || modelID.utf8.count > 200
          || modelID.rangeOfCharacter(from: .whitespacesAndNewlines) != nil) {
        throw AgentFailure(message: "自动化模型 ID 无效。")
      }
      if let reasoning = item.reasoning, AgentReasoningEfforts.titles[reasoning] == nil {
        throw AgentFailure(message: "自动化推理强度无效。")
      }
      if item.cadence == .custom {
        guard let customRule = item.customRule, let anchor = item.scheduleAnchor else {
          throw AgentFailure(message: "自定义日程缺少 RRULE 或起始时间。")
        }
        let rule = try AutomationRecurrenceRule.parse(customRule)
        guard rule.nextDate(after: anchor, anchor: anchor, calendar: .current) != nil else {
          throw AgentFailure(message: "未来十年内找不到该 RRULE 的下次运行时间。")
        }
      }
    }
  }
}
