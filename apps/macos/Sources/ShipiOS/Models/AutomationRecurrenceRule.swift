import Foundation

/// The locally executable RRULE subset. Unsupported fields are rejected rather than ignored.
struct AutomationRecurrenceRule: Equatable {
  enum Frequency: String { case hourly = "HOURLY", daily = "DAILY", weekly = "WEEKLY", monthly = "MONTHLY" }

  let frequency: Frequency
  let interval: Int
  let weekdays: [Int]
  let monthDays: [Int]
  let hour: Int?
  let minute: Int
  let weekStart: Int

  static func parse(_ text: String) throws -> Self {
    var source = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    if source.hasPrefix("RRULE:") { source.removeFirst(6) }
    let allowed: Set<String> = ["FREQ", "INTERVAL", "BYDAY", "BYMONTHDAY", "BYHOUR", "BYMINUTE", "WKST"]
    var fields: [String: String] = [:]
    for part in source.split(separator: ";", omittingEmptySubsequences: false) {
      let pair = part.split(separator: "=", omittingEmptySubsequences: false)
      guard pair.count == 2, allowed.contains(String(pair[0])), !pair[1].isEmpty,
        fields.updateValue(String(pair[1]), forKey: String(pair[0])) == nil
      else { throw AgentFailure(message: "RRULE 包含空值、重复字段或尚不支持的字段。") }
    }
    guard let frequencyText = fields["FREQ"], let frequency = Frequency(rawValue: frequencyText) else {
      throw AgentFailure(message: "RRULE 频率需为 HOURLY、DAILY、WEEKLY 或 MONTHLY。")
    }
    let interval = try number(fields["INTERVAL"] ?? "1", range: 1...366, name: "INTERVAL")
    let minute = try number(fields["BYMINUTE"] ?? "0", range: 0...59, name: "BYMINUTE")
    let hour: Int?
    if frequency == .hourly {
      guard fields["BYHOUR"] == nil else { throw AgentFailure(message: "小时日程不能指定 BYHOUR。") }
      hour = nil
    } else {
      guard let value = fields["BYHOUR"] else { throw AgentFailure(message: "请为日、周、月日程指定 BYHOUR。") }
      hour = try number(value, range: 0...23, name: "BYHOUR")
    }
    let codes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
    let weekdays = try list(fields["BYDAY"], name: "BYDAY") { code in
      guard let index = codes.firstIndex(of: code) else { throw AgentFailure(message: "BYDAY 只支持 SU 至 SA 的星期代码。") }
      return index + 1
    }
    let monthDays = try list(fields["BYMONTHDAY"], name: "BYMONTHDAY") { value in
      guard let number = Int(value), number != 0, (-31...31).contains(number) else {
        throw AgentFailure(message: "BYMONTHDAY 必须是 -31 至 -1 或 1 至 31。")
      }
      return number
    }
    guard frequency != .hourly || (weekdays.isEmpty && monthDays.isEmpty) else {
      throw AgentFailure(message: "小时日程不能指定 BYDAY 或 BYMONTHDAY。")
    }
    let weekStartCode = fields["WKST"] ?? "MO"
    guard let weekStartIndex = codes.firstIndex(of: weekStartCode) else {
      throw AgentFailure(message: "WKST 必须是 SU 至 SA 的星期代码。")
    }
    return Self(frequency: frequency, interval: interval, weekdays: weekdays,
      monthDays: monthDays, hour: hour, minute: minute, weekStart: weekStartIndex + 1)
  }

  func nextDate(after date: Date, anchor: Date, calendar: Calendar) -> Date? {
    var workingCalendar = calendar
    workingCalendar.firstWeekday = weekStart
    let anchorDay = workingCalendar.startOfDay(for: anchor)
    let anchorWeek = workingCalendar.dateInterval(of: .weekOfYear, for: anchor)?.start
    let anchorHour = workingCalendar.dateInterval(of: .hour, for: anchor)?.start
    let anchorParts = workingCalendar.dateComponents([.year, .month, .day, .weekday], from: anchor)
    var day = workingCalendar.startOfDay(for: date)
    for _ in 0..<(366 * 10) {
      if day >= anchorDay, matchesDay(day, anchorDay: anchorDay, anchorWeek: anchorWeek,
        anchorParts: anchorParts, calendar: workingCalendar) {
        let hours = frequency == .hourly ? Array(0..<24) : [hour ?? 0]
        for candidateHour in hours {
          guard let candidate = workingCalendar.date(bySettingHour: candidateHour, minute: minute,
            second: 0, of: day, matchingPolicy: .nextTime, repeatedTimePolicy: .first,
            direction: .forward), workingCalendar.isDate(candidate, inSameDayAs: day),
            workingCalendar.component(.hour, from: candidate) == candidateHour,
            workingCalendar.component(.minute, from: candidate) == minute,
            candidate > date, candidate >= anchor else { continue }
          if frequency == .hourly {
            guard let anchorHour,
              Int(candidate.timeIntervalSince(anchorHour) / 3600) % interval == 0 else { continue }
          }
          return candidate
        }
      }
      guard let followingDay = workingCalendar.date(byAdding: .day, value: 1, to: day) else { return nil }
      day = followingDay
    }
    return nil
  }

  private func matchesDay(_ day: Date, anchorDay: Date, anchorWeek: Date?,
    anchorParts: DateComponents, calendar: Calendar) -> Bool {
    let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
    if !weekdays.isEmpty && !weekdays.contains(parts.weekday ?? 0) { return false }
    if !monthDays.isEmpty {
      guard let dayNumber = parts.day, let daysInMonth = calendar.range(of: .day, in: .month, for: day)?.count,
        monthDays.contains(where: { $0 > 0 ? $0 == dayNumber : daysInMonth + $0 + 1 == dayNumber })
      else { return false }
    }
    switch frequency {
    case .hourly: return true
    case .daily:
      guard let days = calendar.dateComponents([.day], from: anchorDay, to: day).day else { return false }
      return days % interval == 0
    case .weekly:
      guard let anchorWeek, let currentWeek = calendar.dateInterval(of: .weekOfYear, for: day)?.start,
        let weeks = calendar.dateComponents([.weekOfYear], from: anchorWeek, to: currentWeek).weekOfYear
      else { return false }
      return weeks % interval == 0 && (weekdays.isEmpty ? parts.weekday == anchorParts.weekday : true)
    case .monthly:
      guard let year = parts.year, let month = parts.month,
        let anchorYear = anchorParts.year, let anchorMonth = anchorParts.month else { return false }
      let months = (year - anchorYear) * 12 + month - anchorMonth
      return months % interval == 0
        && (monthDays.isEmpty && weekdays.isEmpty ? parts.day == anchorParts.day : true)
    }
  }

  private static func number(_ text: String, range: ClosedRange<Int>, name: String) throws -> Int {
    guard let value = Int(text), range.contains(value) else {
      throw AgentFailure(message: "\(name) 必须在 \(range.lowerBound) 至 \(range.upperBound) 之间。")
    }
    return value
  }

  private static func list(_ text: String?, name: String,
    parse: (String) throws -> Int) throws -> [Int] {
    guard let text else { return [] }
    let pieces = text.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    guard !pieces.contains("") else { throw AgentFailure(message: "\(name) 不能包含空值。") }
    let values = try pieces.map(parse)
    guard Set(values).count == values.count else { throw AgentFailure(message: "\(name) 不能包含重复值。") }
    return values
  }
}
