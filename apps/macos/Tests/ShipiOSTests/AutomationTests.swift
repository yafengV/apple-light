import XCTest

@testable import ShipiOS

final class AutomationTests: XCTestCase {
  private func root() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }

  func testSchedulesAdvanceAndPreferencesPersistWithPrivatePermissions() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
    let start = try XCTUnwrap(calendar.date(from: DateComponents(
      year: 2026, month: 9, day: 17, hour: 8, minute: 45)))
    var item = ShipAutomation(name: "Daily review", prompt: "Review failures")
    item.cadence = .daily
    item.hour = 9
    item.minute = 15
    XCTAssertEqual(
      calendar.dateComponents([.hour, .minute], from: item.nextDate(after: start, calendar: calendar)),
      DateComponents(hour: 9, minute: 15))
    item.cadence = .hourly
    item.minute = 20
    item.modelID = "chosen-model"
    item.reasoning = "high"
    let hourly = item.nextDate(after: start, calendar: calendar)
    XCTAssertEqual(calendar.component(.hour, from: hourly), 9)
    XCTAssertEqual(calendar.component(.minute, from: hourly), 20)

    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    let preferences = AutomationPreferences(items: [item])
    try AutomationStorage.save(preferences, root: base)
    XCTAssertEqual(try AutomationStorage.load(root: base), preferences)
    let attributes = try FileManager.default.attributesOfItem(
      atPath: base.appendingPathComponent("automations.json").path)
    XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
  }

  func testInvalidAutomationModelOrReasoningDoesNotReplaceSavedSchedule() throws {
    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    let valid = ShipAutomation(name: "Valid", prompt: "Review")
    try AutomationStorage.save(AutomationPreferences(items: [valid]), root: base)
    for model in ["", "two words", "bad\nmodel", String(repeating: "x", count: 201)] {
      var invalid = valid
      invalid.modelID = model
      XCTAssertThrowsError(try AutomationStorage.save(AutomationPreferences(items: [invalid]), root: base))
    }
    var invalid = valid
    invalid.reasoning = "unsupported"
    XCTAssertThrowsError(try AutomationStorage.save(AutomationPreferences(items: [invalid]), root: base))
    XCTAssertEqual(try AutomationStorage.load(root: base).items, [valid])
  }

  func testWeeklyScheduleUsesEverySelectedDayAndPersistsLegacySchedules() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
    var item = ShipAutomation(name: "Workdays", prompt: "Review")
    item.cadence = .weekly
    item.hour = 9
    item.minute = 15
    item.setWeekday(4, selected: true) // Wednesday alongside the default Monday.
    XCTAssertEqual(item.selectedWeekdays, [2, 4])
    let monday = try XCTUnwrap(calendar.date(from: DateComponents(
      year: 2026, month: 9, day: 21, hour: 9, minute: 15)))
    let next = item.nextDate(after: monday, calendar: calendar)
    XCTAssertEqual(calendar.dateComponents([.weekday, .hour, .minute], from: next),
      DateComponents(hour: 9, minute: 15, weekday: 4))
    item.setWeekday(2, selected: false)
    XCTAssertEqual(item.selectedWeekdays, [4])
    item.setWeekday(4, selected: false)
    XCTAssertEqual(item.selectedWeekdays, [4], "The last selected day cannot be removed")

    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    try AutomationStorage.save(AutomationPreferences(items: [item]), root: base)
    XCTAssertEqual(try AutomationStorage.load(root: base).items[0].selectedWeekdays, [4])

    var legacy = item
    legacy.weekdays = nil
    legacy.weekday = 6
    let legacyData = try JSONEncoder().encode(AutomationPreferences(items: [legacy]))
    try legacyData.write(to: base.appendingPathComponent("automations.json"))
    XCTAssertEqual(try AutomationStorage.load(root: base).items[0].selectedWeekdays, [6])
  }

  func testInvalidWeeklyDaysDoNotReplaceStoredSchedule() throws {
    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    let valid = ShipAutomation(name: "Valid", prompt: "Review")
    try AutomationStorage.save(AutomationPreferences(items: [valid]), root: base)
    for days in [[Int](), [2, 2], [0], [8], [4, 2]] {
      var invalid = valid
      invalid.weekdays = days
      XCTAssertThrowsError(try AutomationStorage.save(AutomationPreferences(items: [invalid]), root: base))
      XCTAssertEqual(try AutomationStorage.load(root: base).items, [valid])
    }
  }

  func testMultiProjectSelectionPersistsAndLegacyProjectMigrates() throws {
    var item = ShipAutomation(name: "Projects", prompt: "Review")
    XCTAssertEqual(item.selectedProjects, [""])
    XCTAssertEqual(item.selectedExecution, .local)
    item.setProject("/tmp/First", selected: true)
    item.setProject("/tmp/Second", selected: true)
    item.execution = .worktree
    XCTAssertEqual(item.selectedProjects, ["/tmp/First", "/tmp/Second"])
    XCTAssertEqual(item.environmentSelection(for: "/tmp/First"),
      AutomationEnvironmentChoice.projectDefault)
    item.setEnvironment(WorktreeEnvironmentChoice.none, for: "/tmp/First")
    XCTAssertEqual(item.environmentSelection(for: "/tmp/First"), WorktreeEnvironmentChoice.none)
    item.setProject("/tmp/First", selected: false)
    XCTAssertEqual(item.selectedProjects, ["/tmp/Second"])
    XCTAssertNil(item.environmentSelections?["/tmp/First"])
    item.setProject("/tmp/Second", selected: false)
    XCTAssertEqual(item.selectedProjects, [""])
    item.setProject("/tmp/First", selected: true)
    item.setProject("/tmp/Second", selected: true)

    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    try AutomationStorage.save(AutomationPreferences(items: [item]), root: base)
    XCTAssertEqual(try AutomationStorage.load(root: base).items[0].selectedProjects,
      ["/tmp/First", "/tmp/Second"])
    XCTAssertEqual(try AutomationStorage.load(root: base).items[0].selectedExecution, .worktree)
    item.projects = nil
    item.project = "/tmp/Legacy"
    item.execution = nil
    item.environmentSelections = nil
    try JSONEncoder().encode(AutomationPreferences(items: [item])).write(
      to: base.appendingPathComponent("automations.json"))
    XCTAssertEqual(try AutomationStorage.load(root: base).items[0].selectedProjects,
      ["/tmp/Legacy"])
    XCTAssertEqual(try AutomationStorage.load(root: base).items[0].selectedExecution, .local)
    XCTAssertEqual(try AutomationStorage.load(root: base).items[0].environmentSelection(for: "/tmp/Legacy"),
      WorktreeEnvironmentChoice.legacy)
  }

  func testInvalidMultiProjectListIsRejected() throws {
    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    let valid = ShipAutomation(name: "Valid", prompt: "Review")
    try AutomationStorage.save(AutomationPreferences(items: [valid]), root: base)
    for paths in [[String](), ["", "/tmp/First"], ["/tmp/First", "/tmp/First"],
      ["/tmp/Second", "/tmp/First"]] {
      var invalid = valid
      invalid.projects = paths
      invalid.project = paths.first ?? ""
      XCTAssertThrowsError(try AutomationStorage.save(AutomationPreferences(items: [invalid]), root: base))
      XCTAssertEqual(try AutomationStorage.load(root: base).items, [valid])
    }
  }

  func testCustomMonthlyRulesFindFirstAndLastDayAcrossShortMonths() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
    let anchor = try XCTUnwrap(calendar.date(from: DateComponents(
      year: 2026, month: 1, day: 15, hour: 8)))
    let from = try XCTUnwrap(calendar.date(from: DateComponents(
      year: 2026, month: 2, day: 1, hour: 10)))
    let firstDay = try AutomationRecurrenceRule.parse(
      "RRULE:FREQ=MONTHLY;BYMONTHDAY=1;BYHOUR=9;BYMINUTE=0")
    let first = try XCTUnwrap(firstDay.nextDate(after: anchor, anchor: anchor, calendar: calendar))
    XCTAssertEqual(calendar.dateComponents([.month, .day, .hour], from: first),
      DateComponents(month: 2, day: 1, hour: 9))
    let lastDay = try AutomationRecurrenceRule.parse(
      "FREQ=MONTHLY;BYMONTHDAY=-1;BYHOUR=17;BYMINUTE=30")
    let last = try XCTUnwrap(lastDay.nextDate(after: from, anchor: anchor, calendar: calendar))
    XCTAssertEqual(calendar.dateComponents([.month, .day, .hour, .minute], from: last),
      DateComponents(month: 2, day: 28, hour: 17, minute: 30))
  }

  func testCustomWeeklyIntervalAndDayFilter() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
    let anchor = try XCTUnwrap(calendar.date(from: DateComponents(
      year: 2026, month: 9, day: 21, hour: 8))) // Monday
    let rule = try AutomationRecurrenceRule.parse(
      "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE;BYHOUR=9;BYMINUTE=15")
    let first = try XCTUnwrap(rule.nextDate(after: anchor, anchor: anchor, calendar: calendar))
    XCTAssertEqual(calendar.dateComponents([.day, .hour], from: first),
      DateComponents(day: 21, hour: 9))
    let wednesday = try XCTUnwrap(rule.nextDate(after: first, anchor: anchor, calendar: calendar))
    XCTAssertEqual(calendar.component(.day, from: wednesday), 23)
    let nextWeek = try XCTUnwrap(rule.nextDate(after: wednesday, anchor: anchor, calendar: calendar))
    XCTAssertEqual(calendar.dateComponents([.month, .day], from: nextWeek),
      DateComponents(month: 10, day: 5))
  }

  func testCustomMonthlyWeekdayAndHourlyInterval() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
    let anchor = try XCTUnwrap(calendar.date(from: DateComponents(
      year: 2026, month: 1, day: 15, hour: 8, minute: 45)))
    let monday = try AutomationRecurrenceRule.parse("FREQ=MONTHLY;BYDAY=MO;BYHOUR=9;BYMINUTE=0")
    let mondayRun = try XCTUnwrap(monday.nextDate(after: anchor, anchor: anchor, calendar: calendar))
    XCTAssertEqual(calendar.dateComponents([.month, .day, .hour], from: mondayRun),
      DateComponents(month: 1, day: 19, hour: 9))

    let hourly = try AutomationRecurrenceRule.parse("FREQ=HOURLY;INTERVAL=2;BYMINUTE=20")
    let hourlyRun = try XCTUnwrap(hourly.nextDate(after: anchor, anchor: anchor, calendar: calendar))
    XCTAssertEqual(calendar.dateComponents([.day, .hour, .minute], from: hourlyRun),
      DateComponents(day: 15, hour: 10, minute: 20))
  }

  func testCustomYearlyMonthsAndOrdinalWeekdays() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
    let anchor = try XCTUnwrap(calendar.date(from: DateComponents(
      year: 2026, month: 1, day: 15, hour: 8)))
    let yearly = try AutomationRecurrenceRule.parse(
      "FREQ=YEARLY;BYMONTH=3,6;BYMONTHDAY=10;BYHOUR=9;BYMINUTE=0")
    let march = try XCTUnwrap(yearly.nextDate(after: anchor, anchor: anchor, calendar: calendar))
    XCTAssertEqual(calendar.dateComponents([.year, .month, .day, .hour], from: march),
      DateComponents(year: 2026, month: 3, day: 10, hour: 9))
    let june = try XCTUnwrap(yearly.nextDate(after: march, anchor: anchor, calendar: calendar))
    XCTAssertEqual(calendar.dateComponents([.month, .day], from: june),
      DateComponents(month: 6, day: 10))

    let firstMonday = try AutomationRecurrenceRule.parse(
      "FREQ=MONTHLY;BYDAY=1MO;BYHOUR=9;BYMINUTE=0")
    let first = try XCTUnwrap(firstMonday.nextDate(after: anchor, anchor: anchor, calendar: calendar))
    XCTAssertEqual(calendar.dateComponents([.month, .day], from: first),
      DateComponents(month: 2, day: 2))
    let lastFriday = try AutomationRecurrenceRule.parse(
      "FREQ=MONTHLY;BYDAY=-1FR;BYHOUR=9;BYMINUTE=0")
    let last = try XCTUnwrap(lastFriday.nextDate(after: anchor, anchor: anchor, calendar: calendar))
    XCTAssertEqual(calendar.dateComponents([.month, .day], from: last),
      DateComponents(month: 1, day: 30))
    let firstMondayOfYear = try AutomationRecurrenceRule.parse(
      "FREQ=YEARLY;BYDAY=1MO;BYHOUR=9;BYMINUTE=0")
    let nextYear = try XCTUnwrap(firstMondayOfYear.nextDate(
      after: anchor, anchor: anchor, calendar: calendar))
    XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: nextYear),
      DateComponents(year: 2027, month: 1, day: 4))
  }

  func testCustomSetPositionAndMultipleTimes() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
    let anchor = try XCTUnwrap(calendar.date(from: DateComponents(
      year: 2026, month: 1, day: 15, hour: 8)))
    let lastWeekday = try AutomationRecurrenceRule.parse(
      "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1;BYHOUR=9;BYMINUTE=0")
    let january = try XCTUnwrap(lastWeekday.nextDate(after: anchor, anchor: anchor, calendar: calendar))
    XCTAssertEqual(calendar.dateComponents([.month, .day], from: january),
      DateComponents(month: 1, day: 30))
    let february = try XCTUnwrap(lastWeekday.nextDate(after: january, anchor: anchor, calendar: calendar))
    XCTAssertEqual(calendar.dateComponents([.month, .day], from: february),
      DateComponents(month: 2, day: 27))
    let firstMonday = try AutomationRecurrenceRule.parse(
      "FREQ=MONTHLY;BYDAY=MO;BYSETPOS=1;BYHOUR=9;BYMINUTE=0")
    let nextFirstMonday = try XCTUnwrap(firstMonday.nextDate(
      after: anchor, anchor: anchor, calendar: calendar))
    XCTAssertEqual(calendar.dateComponents([.month, .day], from: nextFirstMonday),
      DateComponents(month: 2, day: 2),
      "The first Monday of January is before the anchor; later January Mondays are not first")

    let multiple = try AutomationRecurrenceRule.parse(
      "FREQ=DAILY;BYHOUR=8,9;BYMINUTE=15,45")
    let first = try XCTUnwrap(multiple.nextDate(after: anchor, anchor: anchor, calendar: calendar))
    XCTAssertEqual(calendar.dateComponents([.hour, .minute], from: first),
      DateComponents(hour: 8, minute: 15))
    let second = try XCTUnwrap(multiple.nextDate(after: first, anchor: anchor, calendar: calendar))
    XCTAssertEqual(calendar.dateComponents([.hour, .minute], from: second),
      DateComponents(hour: 8, minute: 45))
    let hourly = try AutomationRecurrenceRule.parse(
      "FREQ=HOURLY;BYMINUTE=10,20;BYSETPOS=-1")
    let hourlyFirst = try XCTUnwrap(hourly.nextDate(after: anchor, anchor: anchor, calendar: calendar))
    XCTAssertEqual(calendar.dateComponents([.hour, .minute], from: hourlyFirst),
      DateComponents(hour: 8, minute: 20))
  }

  func testCustomDailyScheduleSkipsNonexistentDSTLocalTime() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
    let anchor = try XCTUnwrap(calendar.date(from: DateComponents(
      year: 2026, month: 3, day: 7, hour: 2, minute: 30)))
    let rule = try AutomationRecurrenceRule.parse("FREQ=DAILY;BYHOUR=2;BYMINUTE=30")
    let first = try XCTUnwrap(rule.nextDate(after: anchor, anchor: anchor, calendar: calendar))
    XCTAssertEqual(calendar.dateComponents([.day, .hour, .minute], from: first),
      DateComponents(day: 9, hour: 2, minute: 30),
      "March 8 has no 02:30 in this time zone")
  }

  func testCustomRuleValidationRejectsUnsupportedOrImpossibleSchedules() throws {
    for text in [
      "RRULE:FREQ=SECONDLY", "RRULE:FREQ=DAILY;COUNT=0;BYHOUR=9",
      "RRULE:FREQ=DAILY;BYSECOND=60", "RRULE:FREQ=MINUTELY;BYSECOND=-1",
      "RRULE:FREQ=DAILY;COUNT=2;UNTIL=20261001T090000Z",
      "RRULE:FREQ=DAILY;UNTIL=20261001", "RRULE:FREQ=DAILY;UNTIL=20261301T090000Z",
      "RRULE:FREQ=MONTHLY;BYMONTHDAY=0;BYHOUR=9", "RRULE:FREQ=DAILY;BYHOUR=25",
      "RRULE:FREQ=DAILY;BYHOUR=9;BYHOUR=10", "RRULE:FREQ=WEEKLY;BYDAY=MO,MO;BYHOUR=9",
      "RRULE:FREQ=MONTHLY;BYSETPOS=-1", "RRULE:FREQ=MONTHLY;BYDAY=MO;BYSETPOS=0",
      "RRULE:FREQ=DAILY;BYDAY=1MO", "RRULE:FREQ=YEARLY;BYMONTH=1,1",
    ] { XCTAssertThrowsError(try AutomationRecurrenceRule.parse(text), text) }

    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    var item = ShipAutomation(name: "Impossible", prompt: "Review")
    item.cadence = .custom
    item.scheduleAnchor = .now
    item.customRule = "RRULE:FREQ=MONTHLY;INTERVAL=12;BYMONTHDAY=31;BYHOUR=9"
    // The anchor month may have a 31st; choose February to make every scheduled month impossible.
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    item.scheduleAnchor = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 2, day: 1)))
    XCTAssertThrowsError(try AutomationStorage.save(AutomationPreferences(items: [item]), root: base))
    item.customRule = "FREQ=MINUTELY;BYMONTH=2;BYMONTHDAY=31"
    XCTAssertThrowsError(try AutomationStorage.save(AutomationPreferences(items: [item]), root: base))
  }

  func testFiniteCustomRulesStopAfterCountOrInclusiveUntil() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let anchor = try XCTUnwrap(calendar.date(from:
      DateComponents(year: 2026, month: 9, day: 28, hour: 8)))
    let first = try XCTUnwrap(calendar.date(from:
      DateComponents(year: 2026, month: 9, day: 28, hour: 9)))
    let second = try XCTUnwrap(calendar.date(from:
      DateComponents(year: 2026, month: 9, day: 29, hour: 9)))
    let counted = try AutomationRecurrenceRule.parse("FREQ=DAILY;BYHOUR=9;COUNT=2")
    XCTAssertEqual(counted.nextDate(after: anchor, anchor: anchor, calendar: calendar), first)
    XCTAssertEqual(counted.nextDate(after: first, anchor: anchor, calendar: calendar), second)
    XCTAssertNil(counted.nextDate(after: second, anchor: anchor, calendar: calendar))
    let bounded = try AutomationRecurrenceRule.parse(
      "FREQ=DAILY;BYHOUR=9;UNTIL=20260929T090000Z")
    XCTAssertEqual(bounded.nextDate(after: first, anchor: anchor, calendar: calendar), second)
    XCTAssertNil(bounded.nextDate(after: second, anchor: anchor, calendar: calendar))
  }

  func testMinutelyRulesExpandSecondsAndHonorFiniteBounds() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let anchor = try XCTUnwrap(calendar.date(from:
      DateComponents(year: 2026, month: 9, day: 28, hour: 8, second: 10)))
    let counted = try AutomationRecurrenceRule.parse(
      "FREQ=MINUTELY;INTERVAL=15;BYSECOND=10,40;COUNT=4")
    let defaultSeconds = try AutomationRecurrenceRule.parse("FREQ=MINUTELY;INTERVAL=15")
    let defaultNext = try XCTUnwrap(defaultSeconds.nextDate(after: anchor, anchor: anchor, calendar: calendar))
    XCTAssertEqual(calendar.dateComponents([.hour, .minute, .second], from: defaultNext),
      DateComponents(hour: 8, minute: 15, second: 10))
    let first = try XCTUnwrap(counted.nextDate(after: anchor, anchor: anchor, calendar: calendar))
    XCTAssertEqual(calendar.dateComponents([.hour, .minute, .second], from: first),
      DateComponents(hour: 8, minute: 0, second: 40))
    let second = try XCTUnwrap(counted.nextDate(after: first, anchor: anchor, calendar: calendar))
    XCTAssertEqual(calendar.dateComponents([.hour, .minute, .second], from: second),
      DateComponents(hour: 8, minute: 15, second: 10))
    let last = try XCTUnwrap(counted.nextDate(after: second, anchor: anchor, calendar: calendar))
    XCTAssertEqual(calendar.dateComponents([.hour, .minute, .second], from: last),
      DateComponents(hour: 8, minute: 15, second: 40))
    XCTAssertNil(counted.nextDate(after: last, anchor: anchor, calendar: calendar))

    let selected = try AutomationRecurrenceRule.parse(
      "FREQ=MINUTELY;INTERVAL=15;BYSECOND=10,40;BYSETPOS=-1")
    XCTAssertEqual(selected.nextDate(after: anchor, anchor: anchor, calendar: calendar), first)
    let until = try AutomationRecurrenceRule.parse(
      "FREQ=MINUTELY;INTERVAL=15;BYSECOND=40;UNTIL=20260928T081540Z")
    XCTAssertEqual(until.nextDate(after: first, anchor: anchor, calendar: calendar), last)
    XCTAssertNil(until.nextDate(after: last, anchor: anchor, calendar: calendar))
    let daily = try AutomationRecurrenceRule.parse("FREQ=DAILY;BYHOUR=9;BYSECOND=20")
    let dailyNext = try XCTUnwrap(daily.nextDate(after: anchor, anchor: anchor, calendar: calendar))
    XCTAssertEqual(calendar.dateComponents([.hour, .minute, .second], from: dailyNext),
      DateComponents(hour: 9, minute: 0, second: 20))
  }

  @MainActor func testCustomRuleEditingReschedulesAndPersists() async throws {
    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    let store = WorkspaceStore(dataRoot: base)
    await store.loadAutomations()
    var item = ShipAutomation(name: "Custom", prompt: "Review")
    item.cadence = .custom
    item.customRule = "RRULE:FREQ=MONTHLY;BYMONTHDAY=1;BYHOUR=9;BYMINUTE=0"
    XCTAssertTrue(store.saveEditedAutomation(item))
    let saved = try XCTUnwrap(store.automationPreferences.items.first)
    XCTAssertNotNil(saved.scheduleAnchor)
    XCTAssertGreaterThan(saved.nextRun, .now)
    XCTAssertEqual(try AutomationStorage.load(root: base).items[0], saved)

    item = saved
    item.customRule = "RRULE:FREQ=DAILY;BYHOUR=18;BYMINUTE=0"
    XCTAssertTrue(store.saveEditedAutomation(item))
    let changed = store.automationPreferences.items[0]
    XCTAssertEqual(Calendar.current.component(.hour, from: changed.nextRun), 18)
    XCTAssertNotEqual(changed.customRule, saved.customRule)

    item = changed
    item.customRule = "RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=TH;BYSETPOS=4;BYHOUR=9;BYMINUTE=0"
    XCTAssertTrue(store.saveEditedAutomation(item))
    let yearly = store.automationPreferences.items[0]
    XCTAssertEqual(Calendar.current.component(.month, from: yearly.nextRun), 11)
    XCTAssertEqual(Calendar.current.component(.weekday, from: yearly.nextRun), 5)
    XCTAssertEqual(try AutomationStorage.load(root: base).items[0], yearly)
  }

  func testInvalidAutomationIsRejectedWithoutReplacingStoredState() throws {
    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    let valid = ShipAutomation(name: "Valid", prompt: "Do work")
    try AutomationStorage.save(AutomationPreferences(items: [valid]), root: base)
    var invalid = valid
    invalid.name = ""
    XCTAssertThrowsError(try AutomationStorage.save(AutomationPreferences(items: [invalid]), root: base))
    XCTAssertEqual(try AutomationStorage.load(root: base).items, [valid])
  }

  @MainActor func testAutomationPageAndSettingsReturnStayInMainWindowRoute() async {
    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    let store = WorkspaceStore(dataRoot: base)
    await store.loadAutomations()
    XCTAssertTrue(store.automationsLoaded)
    store.draft = "keep automation draft"
    store.executeCommand("automations")
    XCTAssertEqual(store.destination, .automations)
    XCTAssertTrue(store.retainsAutomationsPage)
    store.openSettings(.notifications)
    XCTAssertTrue(store.retainsAutomationsPage)
    store.closeSettings()
    XCTAssertEqual(store.destination, .automations)
    await store.navigate(back: true)
    XCTAssertEqual(store.destination, .workspace)
    XCTAssertEqual(store.draft, "keep automation draft")

    var selection = ComposerCommandSelection()
    selection.update(draft: "/auto", enabled: store.enabledComposerCommands)
    XCTAssertEqual(selection.matches, [.automations])
    store.selectComposerCommand(.automations)
    XCTAssertEqual(store.destination, .automations)
    XCTAssertEqual(store.draft, "")
  }

  @MainActor func testEnablePauseDeleteAndDueSelection() async {
    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    let store = WorkspaceStore(dataRoot: base)
    await store.loadAutomations()
    var item = ShipAutomation(name: "Fixture", prompt: "fixture")
    item.nextRun = Date().addingTimeInterval(3600)
    XCTAssertTrue(store.saveAutomation(item))
    store.setAutomationEnabled(false, id: item.id)
    XCTAssertFalse(store.automationPreferences.items[0].enabled)
    store.setAutomationEnabled(true, id: item.id)
    XCTAssertTrue(store.automationPreferences.items[0].enabled)
    XCTAssertGreaterThan(store.automationPreferences.items[0].nextRun, .now)
    store.deleteAutomation(item.id)
    XCTAssertTrue(store.automationPreferences.items.isEmpty)
  }

  @MainActor func testEditingContentKeepsScheduleButEditingTimeRecomputesIt() async {
    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    let store = WorkspaceStore(dataRoot: base)
    await store.loadAutomations()
    var item = ShipAutomation(name: "Before", prompt: "old prompt")
    item.nextRun = Date().addingTimeInterval(3600)
    XCTAssertTrue(store.saveAutomation(item))
    let original = store.automationPreferences.items[0].nextRun
    item.name = "After"
    item.prompt = "new prompt"
    XCTAssertTrue(store.saveEditedAutomation(item))
    XCTAssertEqual(store.automationPreferences.items[0].nextRun, original)

    item.minute = (item.minute + 1) % 60
    let beforeSave = Date()
    XCTAssertTrue(store.saveEditedAutomation(item))
    let scheduled = store.automationPreferences.items[0].nextRun
    XCTAssertGreaterThanOrEqual(scheduled, item.nextDate(after: beforeSave))
    XCTAssertLessThanOrEqual(scheduled, item.nextDate(after: .now))
  }

  @MainActor func testEditingWeeklyDaysRecomputesNextRun() async {
    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    let store = WorkspaceStore(dataRoot: base)
    await store.loadAutomations()
    var item = ShipAutomation(name: "Weekly", prompt: "Review")
    item.cadence = .weekly
    item.nextRun = Date().addingTimeInterval(3600)
    XCTAssertTrue(store.saveAutomation(item))
    item.setWeekday(4, selected: true)
    XCTAssertTrue(store.saveEditedAutomation(item))
    XCTAssertEqual(store.automationPreferences.items[0].selectedWeekdays, [2, 4])
    XCTAssertEqual(store.automationPreferences.items[0].nextRun,
      item.nextDate(after: store.automationPreferences.items[0].nextRun.addingTimeInterval(-1)),
      "The saved date remains a valid occurrence")
  }

  @MainActor func testEnablingFromEditorRearmsPausedSchedule() async {
    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    let store = WorkspaceStore(dataRoot: base)
    await store.loadAutomations()
    var item = ShipAutomation(name: "Paused", prompt: "review")
    item.enabled = false
    item.nextRun = Date().addingTimeInterval(-3600)
    XCTAssertTrue(store.saveAutomation(item))
    store.automationPreferences.items[0].nextRun = Date().addingTimeInterval(-3600)
    var edited = store.automationPreferences.items[0]
    edited.enabled = true
    XCTAssertTrue(store.saveEditedAutomation(edited))
    XCTAssertGreaterThan(store.automationPreferences.items[0].nextRun, .now)
  }

  @MainActor func testFailedDueRunAdvancesScheduleInsteadOfRetryingEveryPoll() async {
    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    let store = WorkspaceStore(dataRoot: base)
    await store.restore()
    var item = ShipAutomation(name: "Missing service", prompt: "run later")
    item.nextRun = Date().addingTimeInterval(3600)
    XCTAssertTrue(store.saveAutomation(item))
    store.automationPreferences.items[0].nextRun = Date().addingTimeInterval(-60)
    await store.runDueAutomations()
    XCTAssertNotNil(store.automationsError)
    XCTAssertGreaterThan(store.automationPreferences.items[0].nextRun, .now)
    XCTAssertTrue(store.library.chatRuns.isEmpty)
    XCTAssertTrue(store.library.tasks.isEmpty)
  }

  @MainActor func testFiniteDueRunCompletesAndCanRestart() async throws {
    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    let store = WorkspaceStore(dataRoot: base)
    await store.restore()
    var item = ShipAutomation(name: "Finite", prompt: "run once")
    item.cadence = .custom
    item.customRule = "FREQ=DAILY;COUNT=1;BYHOUR=9"
    item.scheduleAnchor = Date().addingTimeInterval(-3 * 86_400)
    item.nextRun = Date().addingTimeInterval(3600)
    XCTAssertTrue(store.saveAutomation(item))
    var due = store.automationPreferences.items[0]
    due.nextRun = Date().addingTimeInterval(-60)
    XCTAssertTrue(store.saveAutomation(due))
    await store.runDueAutomations()
    let completed = try XCTUnwrap(store.automationPreferences.items.first)
    XCTAssertFalse(completed.enabled)
    XCTAssertNotNil(completed.completedAt)
    XCTAssertNotNil(completed.lastRun)
    XCTAssertEqual(try AutomationStorage.load(root: base).items.first?.completedAt, completed.completedAt)
    let lastRun = completed.lastRun
    await store.runDueAutomations()
    XCTAssertEqual(store.automationPreferences.items.first?.lastRun, lastRun)
    var renamed = completed
    renamed.name = "Finite renamed"
    renamed.prompt = "new instructions"
    XCTAssertTrue(store.saveEditedAutomation(renamed))
    XCTAssertEqual(store.automationPreferences.items.first?.completedAt, completed.completedAt)
    store.setAutomationEnabled(true, id: item.id)
    let restarted = try XCTUnwrap(store.automationPreferences.items.first)
    XCTAssertTrue(restarted.enabled)
    XCTAssertNil(restarted.completedAt)
    XCTAssertGreaterThan(restarted.nextRun, .now)
    XCTAssertGreaterThan(restarted.scheduleAnchor ?? .distantPast, completed.scheduleAnchor ?? .distantPast)
  }

  @MainActor func testBusyWorkspaceKeepsDueAutomationForNextPoll() async {
    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    let store = WorkspaceStore(dataRoot: base)
    await store.restore()
    var item = ShipAutomation(name: "Wait for workspace", prompt: "run later")
    item.nextRun = Date().addingTimeInterval(3600)
    XCTAssertTrue(store.saveAutomation(item))
    let due = Date().addingTimeInterval(-60)
    store.automationPreferences.items[0].nextRun = due
    store.busy = true
    await store.runDueAutomations()
    XCTAssertEqual(store.automationPreferences.items[0].nextRun, due)
    XCTAssertTrue(store.library.chatRuns.isEmpty)
    store.busy = false
  }

  @MainActor func testReviewStateDoesNotConsumeAnOverdueSchedule() async {
    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    let store = WorkspaceStore(dataRoot: base)
    await store.restore()
    var item = ShipAutomation(name: "Due review", prompt: "inspect")
    item.nextRun = Date().addingTimeInterval(3600)
    XCTAssertTrue(store.saveAutomation(item))
    let due = Date().addingTimeInterval(-60)
    store.automationPreferences.items[0].nextRun = due
    store.automationPreferences.items[0].lastRunID = "previous"
    store.markAutomationReviewed(item.id)
    XCTAssertEqual(store.automationPreferences.items[0].nextRun, due)
    XCTAssertFalse(store.automationPreferences.items[0].needsReview)
  }

  @MainActor func testMarkAllScheduledRunsReadPreservesSchedulesAndOtherUnreadTasks() async throws {
    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    let store = WorkspaceStore(dataRoot: base)
    await store.restore()
    var first = ShipAutomation(name: "First", prompt: "review")
    first.nextRun = Date().addingTimeInterval(3600)
    first.lastRunID = "first-new"
    first.pendingRunIDs = ["first-old", "first-new"]
    first.activeOccurrenceAt = .now
    var second = ShipAutomation(name: "Second", prompt: "review")
    second.nextRun = Date().addingTimeInterval(3600)
    second.lastRunID = "second-new"
    second.reviewedRunID = "second-old"
    XCTAssertTrue(store.saveAutomation(first))
    XCTAssertTrue(store.saveAutomation(second))
    store.library.tasks = [
      WorkspaceTask(id: "first-task", project: "", title: "First", runIDs: ["first-old", "first-new"]),
      WorkspaceTask(id: "second-task", project: "", title: "Second", runIDs: ["second-new"]),
      WorkspaceTask(id: "other-task", project: "", title: "Other", runIDs: ["other-run"]),
    ]
    store.library.unreadTasks = ["first-task", "second-task", "other-task"]
    XCTAssertTrue(store.saveLibrary())

    store.markAllAutomationsReviewed()
    XCTAssertNil(store.automationsError)
    XCTAssertTrue(store.automationPreferences.items.allSatisfy { !$0.needsReview })
    XCTAssertEqual(store.library.unreadTasks, ["other-task"])
    let savedFirst = try XCTUnwrap(store.automationPreferences.items.first { $0.id == first.id })
    XCTAssertEqual(savedFirst.nextRun, first.nextRun)
    XCTAssertEqual(savedFirst.activeOccurrenceAt, first.activeOccurrenceAt)
    XCTAssertEqual(savedFirst.pendingRunIDs, [])
    XCTAssertEqual(savedFirst.lastRunID, "first-new")
    let persisted = try AutomationStorage.load(root: base)
    XCTAssertTrue(persisted.items.allSatisfy { !$0.needsReview })
    store.markAllAutomationsReviewed()
    XCTAssertEqual(store.library.unreadTasks, ["other-task"])
    await store.shutdown()
  }

  @MainActor func testAppLifecyclePollsDueAutomationWithoutWorkspaceView() async {
    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    let store = WorkspaceStore(dataRoot: base)
    await store.restore()
    var item = ShipAutomation(name: "Background fixture", prompt: "run")
    item.nextRun = Date().addingTimeInterval(3600)
    XCTAssertTrue(store.saveAutomation(item))
    store.automationPreferences.items[0].nextRun = Date().addingTimeInterval(-60)
    let delegate = AppDelegate()
    delegate.store = store
    delegate.startAutomationPolling(every: .milliseconds(20))
    for _ in 0..<50 where store.automationsError == nil {
      try? await Task.sleep(for: .milliseconds(20))
    }
    delegate.stopAutomationPolling()
    XCTAssertNotNil(store.automationsError)
    XCTAssertGreaterThan(store.automationPreferences.items[0].nextRun, .now)
    await store.shutdown()
  }
}
