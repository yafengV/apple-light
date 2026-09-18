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
  }
}
