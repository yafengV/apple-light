import Foundation

/// The locally executable RRULE subset. Unsupported fields are rejected rather than ignored.
struct AutomationRecurrenceRule: Equatable {
  enum Frequency: String {
    case minutely = "MINUTELY", hourly = "HOURLY", daily = "DAILY", weekly = "WEEKLY",
      monthly = "MONTHLY", yearly = "YEARLY"
  }

  struct Weekday: Equatable {
    let day: Int
    let ordinal: Int?
  }

  let frequency: Frequency
  let interval: Int
  let weekdays: [Weekday]
  let monthDays: [Int]
  let months: [Int]
  let setPositions: [Int]
  let hours: [Int]
  let minutes: [Int]
  let seconds: [Int]
  let weekStart: Int
  let count: Int?
  let until: Date?

  static func parse(_ text: String) throws -> Self {
    var source = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    if source.hasPrefix("RRULE:") { source.removeFirst(6) }
    let allowed: Set<String> = ["FREQ", "INTERVAL", "BYDAY", "BYMONTHDAY", "BYMONTH",
      "BYSETPOS", "BYHOUR", "BYMINUTE", "BYSECOND", "WKST", "COUNT", "UNTIL"]
    var fields: [String: String] = [:]
    for part in source.split(separator: ";", omittingEmptySubsequences: false) {
      let pair = part.split(separator: "=", omittingEmptySubsequences: false)
      guard pair.count == 2, allowed.contains(String(pair[0])), !pair[1].isEmpty,
        fields.updateValue(String(pair[1]), forKey: String(pair[0])) == nil
      else { throw AgentFailure(message: "RRULE 包含空值、重复字段或尚不支持的字段。") }
    }
    guard let frequencyText = fields["FREQ"], let frequency = Frequency(rawValue: frequencyText) else {
      throw AgentFailure(message: "RRULE 频率需为 MINUTELY、HOURLY、DAILY、WEEKLY、MONTHLY 或 YEARLY。")
    }
    let interval = try number(fields["INTERVAL"] ?? "1", range: 1...10_080, name: "INTERVAL")
    guard fields["COUNT"] == nil || fields["UNTIL"] == nil else {
      throw AgentFailure(message: "COUNT 与 UNTIL 不能同时使用。")
    }
    let count = try fields["COUNT"].map { try number($0, range: 1...100_000, name: "COUNT") }
    let until: Date?
    if let text = fields["UNTIL"] {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)!
      formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
      formatter.isLenient = false
      guard text.range(of: #"^\d{8}T\d{6}Z$"#, options: .regularExpression) != nil,
        let parsed = formatter.date(from: text), formatter.string(from: parsed) == text else {
        throw AgentFailure(message: "UNTIL 必须是 UTC 时间，例如 20261001T090000Z。")
      }
      until = parsed
    } else { until = nil }
    let minutes = try list(fields["BYMINUTE"], name: "BYMINUTE") {
      try number($0, range: 0...59, name: "BYMINUTE")
    }
    let seconds = try list(fields["BYSECOND"], name: "BYSECOND") {
      try number($0, range: 0...59, name: "BYSECOND")
    }
    let hours = try list(fields["BYHOUR"], name: "BYHOUR") {
      try number($0, range: 0...23, name: "BYHOUR")
    }
    let codes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
    let weekdays: [Weekday] = try weekdayList(fields["BYDAY"], codes: codes)
    guard (frequency == .monthly || frequency == .yearly)
      || weekdays.allSatisfy({ $0.ordinal == nil }) else {
      throw AgentFailure(message: "带序号的 BYDAY 只适用于月或年日程。")
    }
    let monthDays = try list(fields["BYMONTHDAY"], name: "BYMONTHDAY") { value in
      guard let number = Int(value), number != 0, (-31...31).contains(number) else {
        throw AgentFailure(message: "BYMONTHDAY 必须是 -31 至 -1 或 1 至 31。")
      }
      return number
    }
    let months = try list(fields["BYMONTH"], name: "BYMONTH") {
      try number($0, range: 1...12, name: "BYMONTH")
    }
    let setPositions = try list(fields["BYSETPOS"], name: "BYSETPOS") { value in
      guard let position = Int(value), position != 0, (-366...366).contains(position) else {
        throw AgentFailure(message: "BYSETPOS 必须是 -366 至 -1 或 1 至 366。")
      }
      return position
    }
    guard setPositions.isEmpty || ["BYDAY", "BYMONTHDAY", "BYMONTH", "BYHOUR", "BYMINUTE", "BYSECOND"]
      .contains(where: { fields[$0] != nil }) else {
      throw AgentFailure(message: "BYSETPOS 必须与其他 BY 字段一起使用。")
    }
    let weekStartCode = fields["WKST"] ?? "MO"
    guard let weekStartIndex = codes.firstIndex(of: weekStartCode) else {
      throw AgentFailure(message: "WKST 必须是 SU 至 SA 的星期代码。")
    }
    return Self(frequency: frequency, interval: interval, weekdays: weekdays,
      monthDays: monthDays, months: months, setPositions: setPositions,
      hours: hours, minutes: minutes, seconds: seconds, weekStart: weekStartIndex + 1,
      count: count, until: until)
  }

  func nextDate(after date: Date, anchor: Date, calendar: Calendar) -> Date? {
    if frequency == .minutely { return nextMinutelyDate(after: date, anchor: anchor, calendar: calendar) }
    var workingCalendar = calendar
    workingCalendar.firstWeekday = weekStart
    let anchorDay = workingCalendar.startOfDay(for: anchor)
    let anchorWeek = workingCalendar.dateInterval(of: .weekOfYear, for: anchor)?.start
    let anchorHour = workingCalendar.dateInterval(of: .hour, for: anchor)?.start
    let anchorParts = workingCalendar.dateComponents([.year, .month, .day, .weekday, .hour], from: anchor)
    var day = count == nil ? workingCalendar.startOfDay(for: date) : anchorDay
    var occurrenceCount = 0
    var selectedPeriodStart: Date?
    var selectedPeriodDates: Set<Date> = []
    for _ in 0..<(366 * 10) {
      if day >= anchorDay, matchesDay(day, anchorDay: anchorDay, anchorWeek: anchorWeek,
        anchorParts: anchorParts, calendar: workingCalendar) {
        for candidate in candidateTimes(on: day, anchorHour: anchorHour,
          anchorParts: anchorParts, calendar: workingCalendar) where candidate >= anchor {
          if let until, candidate > until { return nil }
          if !setPositions.isEmpty {
            guard let period = workingCalendar.dateInterval(of: periodComponent, for: candidate) else { continue }
            if selectedPeriodStart != period.start {
              selectedPeriodStart = period.start
              selectedPeriodDates = selectedDates(in: period, anchorDay: anchorDay,
                anchorWeek: anchorWeek, anchorHour: anchorHour, anchorParts: anchorParts,
                calendar: workingCalendar)
            }
            if !selectedPeriodDates.contains(candidate) { continue }
          }
          occurrenceCount += 1
          if let count, occurrenceCount > count { return nil }
          if candidate > date { return candidate }
        }
      }
      if let until, day > until { return nil }
      guard let followingDay = workingCalendar.date(byAdding: .day, value: 1, to: day) else { return nil }
      day = followingDay
    }
    return nil
  }

  private func nextMinutelyDate(after date: Date, anchor: Date, calendar: Calendar) -> Date? {
    var workingCalendar = calendar
    workingCalendar.firstWeekday = weekStart
    guard let anchorMinute = workingCalendar.dateInterval(of: .minute, for: anchor)?.start else { return nil }
    let anchorDay = workingCalendar.startOfDay(for: anchor)
    let anchorWeek = workingCalendar.dateInterval(of: .weekOfYear, for: anchor)?.start
    let anchorParts = workingCalendar.dateComponents([.year, .month, .day, .weekday, .hour, .second], from: anchor)
    let allSeconds = (seconds.isEmpty ? [anchorParts.second ?? 0] : seconds).sorted()
    let selectedSeconds: [Int]
    if setPositions.isEmpty { selectedSeconds = allSeconds }
    else {
      selectedSeconds = Array(Set(setPositions.compactMap { position -> Int? in
        let index = position > 0 ? position - 1 : allSeconds.count + position
        return allSeconds.indices.contains(index) ? allSeconds[index] : nil
      })).sorted()
    }
    let step = TimeInterval(interval * 60)
    let firstSlot = count == nil
      ? max(0, Int(floor(max(0, date.timeIntervalSince(anchorMinute)) / step))) : 0
    let horizon = (count == nil ? max(date, anchor) : anchor).addingTimeInterval(366 * 10 * 86_400)
    var occurrenceCount = 0
    var slotNumber = firstSlot
    while true {
      let slot = anchorMinute.addingTimeInterval(TimeInterval(slotNumber) * step)
      if slot > horizon { return nil }
      if let until, slot > until { return nil }
      let day = workingCalendar.startOfDay(for: slot)
      guard matchesDay(day, anchorDay: anchorDay, anchorWeek: anchorWeek,
        anchorParts: anchorParts, calendar: workingCalendar) else {
        guard let nextDay = workingCalendar.date(byAdding: .day, value: 1, to: day) else { return nil }
        slotNumber = max(slotNumber + 1,
          Int(ceil(nextDay.timeIntervalSince(anchorMinute) / step)))
        continue
      }
      let parts = workingCalendar.dateComponents([.hour, .minute], from: slot)
      if !hours.isEmpty && !hours.contains(parts.hour ?? -1) {
        guard let hour = workingCalendar.dateInterval(of: .hour, for: slot) else { return nil }
        slotNumber = max(slotNumber + 1,
          Int(ceil(hour.end.timeIntervalSince(anchorMinute) / step)))
        continue
      }
      if minutes.isEmpty || minutes.contains(parts.minute ?? -1) {
        for second in selectedSeconds {
          let candidate = slot.addingTimeInterval(TimeInterval(second))
          if candidate < anchor { continue }
          if let until, candidate > until { return nil }
          occurrenceCount += 1
          if let count, occurrenceCount > count { return nil }
          if candidate > date { return candidate }
        }
      }
      slotNumber += 1
    }
  }

  private var periodComponent: Calendar.Component {
    switch frequency {
    case .minutely: .minute
    case .hourly: .hour
    case .daily: .day
    case .weekly: .weekOfYear
    case .monthly: .month
    case .yearly: .year
    }
  }

  private func selectedDates(in period: DateInterval, anchorDay: Date,
    anchorWeek: Date?, anchorHour: Date?, anchorParts: DateComponents,
    calendar: Calendar) -> Set<Date> {
    var candidates: [Date] = []
    var day = calendar.startOfDay(for: period.start)
    while day < period.end {
      if matchesDay(day, anchorDay: anchorDay, anchorWeek: anchorWeek,
        anchorParts: anchorParts, calendar: calendar) {
        candidates += candidateTimes(on: day, anchorHour: anchorHour,
          anchorParts: anchorParts, calendar: calendar).filter {
            $0 >= period.start && $0 < period.end
          }
      }
      guard let followingDay = calendar.date(byAdding: .day, value: 1, to: day) else { break }
      day = followingDay
    }
    candidates.sort()
    var selected: Set<Date> = []
    for position in setPositions {
      let index = position > 0 ? position - 1 : candidates.count + position
      if candidates.indices.contains(index) { selected.insert(candidates[index]) }
    }
    return selected
  }

  private func candidateTimes(on day: Date, anchorHour: Date?,
    anchorParts: DateComponents, calendar: Calendar) -> [Date] {
    let candidateHours = hours.isEmpty
      ? (frequency == .hourly ? Array(0..<24) : [anchorParts.hour ?? 0]) : hours
    let candidateMinutes = minutes.isEmpty ? [0] : minutes
    let candidateSeconds = seconds.isEmpty ? [0] : seconds
    var dates: [Date] = []
    for candidateHour in candidateHours {
      for candidateMinute in candidateMinutes {
        for candidateSecond in candidateSeconds {
          guard let candidate = calendar.date(bySettingHour: candidateHour, minute: candidateMinute,
            second: candidateSecond, of: day, matchingPolicy: .nextTime, repeatedTimePolicy: .first,
            direction: .forward), calendar.isDate(candidate, inSameDayAs: day),
            calendar.component(.hour, from: candidate) == candidateHour,
            calendar.component(.minute, from: candidate) == candidateMinute,
            calendar.component(.second, from: candidate) == candidateSecond else { continue }
          if frequency == .hourly {
            guard let anchorHour,
              Int(candidate.timeIntervalSince(anchorHour) / 3600) % interval == 0 else { continue }
          }
          dates.append(candidate)
        }
      }
    }
    return dates.sorted()
  }

  private func matchesDay(_ day: Date, anchorDay: Date, anchorWeek: Date?,
    anchorParts: DateComponents, calendar: Calendar) -> Bool {
    let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
    if !months.isEmpty && !months.contains(parts.month ?? 0) { return false }
    if !weekdays.isEmpty && !weekdays.contains(where: { specifier in
      guard specifier.day == parts.weekday else { return false }
      guard let ordinal = specifier.ordinal else { return true }
      if frequency == .yearly && months.isEmpty {
        guard let dayOfYear = calendar.ordinality(of: .day, in: .year, for: day),
          let daysInYear = calendar.range(of: .day, in: .year, for: day)?.count else { return false }
        return ordinal > 0 ? (dayOfYear - 1) / 7 + 1 == ordinal
          : (daysInYear - dayOfYear) / 7 + 1 == -ordinal
      }
      guard let dayOfMonth = parts.day,
        let daysInMonth = calendar.range(of: .day, in: .month, for: day)?.count else { return false }
      return ordinal > 0 ? (dayOfMonth - 1) / 7 + 1 == ordinal
        : (daysInMonth - dayOfMonth) / 7 + 1 == -ordinal
    }) { return false }
    if !monthDays.isEmpty {
      guard let dayNumber = parts.day, let daysInMonth = calendar.range(of: .day, in: .month, for: day)?.count,
        monthDays.contains(where: { $0 > 0 ? $0 == dayNumber : daysInMonth + $0 + 1 == dayNumber })
      else { return false }
    }
    switch frequency {
    case .minutely, .hourly: return true
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
    case .yearly:
      guard let year = parts.year, let anchorYear = anchorParts.year else { return false }
      return (year - anchorYear) % interval == 0
        && (monthDays.isEmpty && weekdays.isEmpty ? parts.day == anchorParts.day : true)
        && (!months.isEmpty || parts.month == anchorParts.month || !monthDays.isEmpty || !weekdays.isEmpty)
    }
  }

  private static func weekdayList(_ text: String?, codes: [String]) throws -> [Weekday] {
    guard let text else { return [] }
    let pieces = text.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    guard !pieces.contains(""), Set(pieces).count == pieces.count else {
      throw AgentFailure(message: "BYDAY 不能包含空值或重复值。")
    }
    return try pieces.map { value in
      let code = String(value.suffix(2))
      guard let index = codes.firstIndex(of: code) else {
        throw AgentFailure(message: "BYDAY 必须使用 SU 至 SA 的星期代码。")
      }
      let prefix = String(value.dropLast(2))
      let ordinal: Int?
      if prefix.isEmpty { ordinal = nil }
      else {
        guard let number = Int(prefix), number != 0, (-53...53).contains(number) else {
          throw AgentFailure(message: "BYDAY 的星期序号必须是 -53 至 -1 或 1 至 53。")
        }
        ordinal = number
      }
      return Weekday(day: index + 1, ordinal: ordinal)
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
