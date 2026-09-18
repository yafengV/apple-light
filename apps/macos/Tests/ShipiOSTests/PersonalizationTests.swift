import XCTest

@testable import ShipiOS

final class PersonalizationTests: XCTestCase {
  private func root() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }

  func testLegacyInstructionsMigrateOnceAndClearingDoesNotResurrectThem() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = "请用中文回答。\n保留完整代码。"
    let first = try PersonalizationStorage.load(root: root, legacyInstructions: legacy)
    XCTAssertEqual(first.0.personality, .none)
    XCTAssertEqual(first.1, legacy)
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("AGENTS.md"), encoding: .utf8), legacy)
    try PersonalizationStorage.saveInstructions("", root: root)
    XCTAssertEqual(try PersonalizationStorage.load(root: root, legacyInstructions: legacy).1, "")
    try FileManager.default.removeItem(at: root.appendingPathComponent("AGENTS.md"))
    XCTAssertEqual(try PersonalizationStorage.load(root: root, legacyInstructions: legacy).1, "")
  }

  func testExistingAgentsFileTakesPrecedenceAndNoneOnlyRemovesStyle() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    try PersonalizationStorage.saveInstructions("Existing instructions", root: root)
    let loaded = try PersonalizationStorage.load(root: root, legacyInstructions: "Old instructions")
    XCTAssertEqual(loaded.1, "Existing instructions")
    let friendly = Personalization(personality: .friendly).systemInstructions(custom: loaded.1)
    XCTAssertTrue(friendly.contains(ResponsePersonality.friendly.instruction))
    let none = Personalization(personality: .none).systemInstructions(custom: loaded.1)
    XCTAssertEqual(none, Personalization.baseInstructions + "\n\nExisting instructions")
    XCTAssertFalse(none.contains(ResponsePersonality.friendly.instruction))
  }

  func testLegacyPreferencesEnableSuggestedPrompts() throws {
    let legacy = try JSONDecoder().decode(
      Personalization.self, from: Data(#"{"personality":"friendly"}"#.utf8))
    XCTAssertEqual(legacy.personality, .friendly)
    XCTAssertTrue(legacy.showSuggestedPrompts)
  }

  func testInvalidOrOversizedInstructionsAreNotOverwritten() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("AGENTS.md")
    for data in [Data([0xff, 0xfe]), Data(repeating: 65, count: 65_537)] {
      try data.write(to: url)
      XCTAssertThrowsError(try PersonalizationStorage.load(root: root, legacyInstructions: "legacy"))
      XCTAssertEqual(try Data(contentsOf: url), data)
    }
    try PersonalizationStorage.saveInstructions("keep", root: root)
    XCTAssertThrowsError(try PersonalizationStorage.saveInstructions(String(repeating: "中", count: 30_000), root: root))
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "keep")
  }

  @MainActor func testPreferencesSaveWithoutAPIAndStayIsolatedAcrossRoots() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = WorkspaceStore(dataRoot: root.appendingPathComponent("a"))
    let second = WorkspaceStore(dataRoot: root.appendingPathComponent("b"))
    await first.loadPersonalization()
    await second.loadPersonalization()
    XCTAssertTrue(first.modelConfiguration.baseURL.isEmpty)
    first.personalizationDraft = "Use SwiftUI"
    XCTAssertTrue(first.saveCustomInstructions())
    XCTAssertTrue(first.saveSuggestedPrompts(false))
    XCTAssertTrue(first.savePersonality(.pragmatic))
    XCTAssertFalse(first.personalization.showSuggestedPrompts)
    let restored = WorkspaceStore(dataRoot: first.dataRoot)
    await restored.loadPersonalization()
    XCTAssertEqual(restored.customInstructions, "Use SwiftUI")
    XCTAssertEqual(restored.personalization.personality, .pragmatic)
    XCTAssertFalse(restored.personalization.showSuggestedPrompts)
    XCTAssertTrue(second.customInstructions.isEmpty)
    XCTAssertEqual(second.personalization.personality, .none)
    XCTAssertFalse(FileManager.default.fileExists(atPath: first.dataRoot.appendingPathComponent("model.json").path))
    for file in ["AGENTS.md", "personalization.json"] {
      let attributes = try FileManager.default.attributesOfItem(atPath: first.dataRoot.appendingPathComponent(file).path)
      XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    }
  }

  @MainActor func testUnsavedEditsSurvivePageNavigationAndDoNotEnterRequests() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.loadPersonalization()
    store.openSettings(.personalization)
    store.personalizationDraft = "Unsubmitted preference"
    store.settingsPage = .model
    store.closeSettings()
    store.openSettings(.personalization)
    XCTAssertEqual(store.personalizationDraft, "Unsubmitted preference")
    XCTAssertFalse(store.systemInstructions.contains("Unsubmitted preference"))
    await store.loadPersonalization()
    XCTAssertEqual(store.personalizationDraft, "Unsubmitted preference")
    XCTAssertTrue(store.saveCustomInstructions())
    XCTAssertTrue(store.systemInstructions.contains("Unsubmitted preference"))
  }

  @MainActor func testCorruptPreferencesBlockWritesUntilSuccessfulReload() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("personalization.json")
    let broken = Data("broken".utf8)
    try broken.write(to: url)
    let store = WorkspaceStore(dataRoot: root)
    await store.loadPersonalization()
    XCTAssertFalse(store.personalizationLoaded)
    XCTAssertNotNil(store.personalizationError)
    XCTAssertFalse(store.savePersonality(.friendly))
    XCTAssertFalse(store.saveCustomInstructions())
    XCTAssertEqual(try Data(contentsOf: url), broken)
    try PersonalizationStorage.save(Personalization(), root: root)
    await store.loadPersonalization()
    XCTAssertTrue(store.personalizationLoaded)
    XCTAssertNil(store.personalizationError)
  }

  @MainActor func testChatDoesNotSilentlyDropUnreadablePersonalInstructions() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data([0xff]).write(to: root.appendingPathComponent("AGENTS.md"))
    let store = WorkspaceStore(dataRoot: root)
    store.project = root
    store.connected = true
    store.modelConfiguration.baseURL = "https://example.com/v1"
    store.modelConfiguration.model = "fixture"
    store.draft = "preserve this prompt"
    await store.loadPersonalization()
    await store.startChat(store.draft, consumeDraft: true)
    XCTAssertTrue(store.library.chatRuns.isEmpty)
    XCTAssertEqual(store.draft, "preserve this prompt")
    XCTAssertTrue(store.error?.contains("个人指令") == true)
  }
}
