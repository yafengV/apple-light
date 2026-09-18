import XCTest

@testable import ShipiOS

final class MemoryTests: XCTestCase {
  private func root() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }

  func testLegacyPreferencesDefaultToEnabledAndEmpty() throws {
    let preferences = try JSONDecoder().decode(
      MemoryPreferences.self, from: Data(#"{}"#.utf8))
    XCTAssertTrue(preferences.enabled)
    XCTAssertTrue(preferences.items.isEmpty)
  }

  func testStorageRoundTripValidationAndPermissions() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let item = SavedMemory(text: "优先使用 SwiftUI")
    let preferences = MemoryPreferences(enabled: false, items: [item])
    try MemoryStorage.save(preferences, root: root)
    XCTAssertEqual(try MemoryStorage.load(root: root), preferences)
    let attributes = try FileManager.default.attributesOfItem(
      atPath: root.appendingPathComponent("memories.json").path)
    XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    XCTAssertThrowsError(
      try MemoryStorage.save(
        MemoryPreferences(items: [SavedMemory(text: String(repeating: "a", count: 4_097))]),
        root: root))
    XCTAssertEqual(try MemoryStorage.load(root: root), preferences)
  }

  @MainActor func testMutationsPersistStayIsolatedAndEnterSystemInstructions() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = WorkspaceStore(dataRoot: root.appendingPathComponent("a"))
    let second = WorkspaceStore(dataRoot: root.appendingPathComponent("b"))
    await first.loadMemories()
    await second.loadMemories()
    first.memoryDraft = "  回复时优先给出可运行代码。  "
    XCTAssertTrue(first.addMemory(first.memoryDraft))
    XCTAssertTrue(first.memoryDraft.isEmpty)
    guard let memory = first.memoryPreferences.items.first else { return XCTFail("missing memory") }
    XCTAssertTrue(first.systemInstructions.contains("回复时优先给出可运行代码。"))
    XCTAssertTrue(first.updateMemory(memory.id, text: "优先给出可运行的 Swift 代码。"))
    XCTAssertFalse(first.systemInstructions.contains("回复时优先给出可运行代码。"))
    XCTAssertTrue(first.systemInstructions.contains("优先给出可运行的 Swift 代码。"))
    XCTAssertTrue(first.saveMemoryEnabled(false))
    XCTAssertFalse(first.systemInstructions.contains("优先给出可运行的 Swift 代码。"))

    let restored = WorkspaceStore(dataRoot: first.dataRoot)
    await restored.loadMemories()
    XCTAssertFalse(restored.memoryPreferences.enabled)
    XCTAssertEqual(restored.memoryPreferences.items.first?.text, "优先给出可运行的 Swift 代码。")
    XCTAssertTrue(second.memoryPreferences.items.isEmpty)
    XCTAssertTrue(restored.deleteMemory(memory.id))
    XCTAssertTrue(restored.memoryPreferences.items.isEmpty)
  }

  @MainActor func testDuplicateInvalidAndMissingMutationsDoNotChangeState() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.loadMemories()
    XCTAssertFalse(store.addMemory("   "))
    XCTAssertTrue(store.addMemory("same"))
    let snapshot = store.memoryPreferences
    XCTAssertFalse(store.addMemory("same"))
    XCTAssertFalse(store.updateMemory(UUID(), text: "other"))
    XCTAssertFalse(store.deleteMemory(UUID()))
    XCTAssertEqual(store.memoryPreferences, snapshot)
  }

  @MainActor func testCorruptMemoryStopsChatWithoutConsumingDraft() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("broken".utf8).write(to: root.appendingPathComponent("memories.json"))
    let store = WorkspaceStore(dataRoot: root)
    store.connected = true
    store.project = root
    store.modelConfiguration.baseURL = "https://example.com/v1"
    store.modelConfiguration.model = "fixture"
    store.personalizationLoaded = true
    store.draft = "preserve memory prompt"
    await store.loadMemories()
    XCTAssertFalse(store.memoriesLoaded)
    await store.startChat(store.draft, consumeDraft: true)
    XCTAssertTrue(store.library.chatRuns.isEmpty)
    XCTAssertEqual(store.draft, "preserve memory prompt")
    XCTAssertTrue(store.error?.contains("记忆") == true)
  }
}
