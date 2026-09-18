import AppKit
import XCTest

@testable import ShipiOS

final class ProfileTests: XCTestCase {
  private func root() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }

  func testProfileValidationPersistenceAndPermissions() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let profile = ProfilePreferences(displayName: " ShipiOS 用户 ", username: "ship_ios", hasAvatar: false)
    try ProfileStorage.save(profile, root: root)
    XCTAssertEqual(
      try ProfileStorage.load(root: root),
      ProfilePreferences(displayName: "ShipiOS 用户", username: "ship_ios", hasAvatar: false))
    let attributes = try FileManager.default.attributesOfItem(
      atPath: root.appendingPathComponent("profile.json").path)
    XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    XCTAssertThrowsError(
      try ProfileStorage.save(ProfilePreferences(username: "bad name"), root: root))
    XCTAssertEqual(try ProfileStorage.load(root: root).username, "ship_ios")
  }

  func testActivityUsesOnlyStoredAuthoritativeUsage() {
    var library = WorkspaceLibrary()
    let calendar = Calendar(identifier: .gregorian)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let today = calendar.startOfDay(for: now)
    for (index, offset) in [0, -1, -3].enumerated() {
      let date = calendar.date(byAdding: .day, value: offset, to: today)!
      let usage = index < 2
        ? ModelTokenUsage(inputTokens: 10 + index, outputTokens: 5, totalTokens: 15 + index)
        : nil
      let run = AgentRun(
        id: "run-\(index)", kind: "chat", project: "", status: "succeeded",
        createdAt: date.timeIntervalSince1970 * 1_000,
        updatedAt: date.timeIntervalSince1970 * 1_000 + Double((index + 1) * 1_000),
        request: .object(["model": .string("fixture")]),
        result: .object([
          "response": .string("ok"),
          "usage": usage?.jsonValue ?? .null,
        ]))
      library.attach(run, to: nil, note: "task \(index)")
      library.chatRuns.append(run)
    }
    let activity = library.profileActivity(now: now, calendar: calendar)
    XCTAssertEqual(activity.lifetimeTokens, 31)
    XCTAssertEqual(activity.peakTokens, 16)
    XCTAssertEqual(activity.activeStreak, 2)
    XCTAssertEqual(activity.taskCount, 3)
    XCTAssertEqual(activity.turnCount, 3)
  }

  @MainActor func testStoreSavesProfileAndAvatarInIndependentRoot() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.loadProfile()
    store.profileNameDraft = "Taylor"
    store.profileUsernameDraft = "taylor.dev"
    XCTAssertTrue(store.saveUserProfile())
    let image = NSImage(size: NSSize(width: 2, height: 2))
    image.lockFocus()
    NSColor.blue.setFill()
    NSRect(x: 0, y: 0, width: 2, height: 2).fill()
    image.unlockFocus()
    let data = try XCTUnwrap(
      NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?
        .representation(using: .png, properties: [:]))
    XCTAssertTrue(store.importProfileAvatar(data))
    XCTAssertTrue(store.profile.hasAvatar)
    XCTAssertEqual(store.profile.initials, "T")
    let restored = WorkspaceStore(dataRoot: root)
    await restored.loadProfile()
    XCTAssertEqual(restored.profile.displayName, "Taylor")
    XCTAssertEqual(restored.profile.username, "taylor.dev")
    XCTAssertNotNil(restored.profileAvatar)
    XCTAssertTrue(restored.removeProfileAvatar())
    XCTAssertFalse(FileManager.default.fileExists(atPath: ProfileStorage.avatarURL(root: root).path))
  }

  func testProfileCardIsValidPNG() throws {
    let activity = ProfileActivity(
      lifetimeTokens: 12_345, peakTokens: 4_321, activeStreak: 7, taskCount: 12,
      turnCount: 34, longestTaskTitle: "Long task", longestTaskDuration: 90)
    let data = try ProfileCardRenderer.render(
      profile: ProfilePreferences(displayName: "ShipiOS User", username: "shipios"),
      activity: activity)
    XCTAssertEqual(Array(data.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
    XCTAssertNotNil(NSImage(data: data))
  }
}
