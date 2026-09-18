import XCTest

@testable import ShipiOS

final class ComputerUseTests: XCTestCase {
  func testPreferencesRoundTripValidatesDuplicatesAndPermissions() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let application = ComputerUseApplication(
      name: "Calculator.app", bundleIdentifier: "com.apple.calculator",
      path: "/System/Applications/Calculator.app")
    var preferences = ComputerUsePreferences()
    preferences.anyAppEnabled = true
    preferences.alwaysAllowedApplications = [application, application]
    try ComputerUseStorage.save(preferences, root: root)

    let loaded = try ComputerUseStorage.load(root: root)
    XCTAssertTrue(loaded.anyAppEnabled)
    XCTAssertEqual(loaded.alwaysAllowedApplications, [application])
    let attributes = try FileManager.default.attributesOfItem(
      atPath: ComputerUseStorage.file(root: root).path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
  }

  @MainActor func testStorePersistsAnyAppAndAllowListAcrossRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")
    guard FileManager.default.fileExists(atPath: calculator.path) else {
      throw XCTSkip("Calculator.app is unavailable")
    }
    let first = WorkspaceStore(dataRoot: root)
    await first.loadComputerUsePreferences()
    XCTAssertTrue(first.setAnyAppComputerUse(true))
    XCTAssertTrue(first.addAlwaysAllowedApplication(calculator))

    let second = WorkspaceStore(dataRoot: root)
    await second.loadComputerUsePreferences()
    XCTAssertTrue(second.computerUsePreferences.anyAppEnabled)
    XCTAssertEqual(second.computerUsePreferences.alwaysAllowedApplications.count, 1)
    XCTAssertTrue(
      second.removeAlwaysAllowedApplication(
        try XCTUnwrap(second.computerUsePreferences.alwaysAllowedApplications.first)))
    XCTAssertTrue(second.computerUsePreferences.alwaysAllowedApplications.isEmpty)
  }
}
