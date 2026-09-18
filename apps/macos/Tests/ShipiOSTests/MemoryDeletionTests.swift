import XCTest
@testable import ShipiOS

@MainActor final class MemoryDeletionTests: XCTestCase {
  private func makeStore(_ root: URL) async -> WorkspaceStore {
    let store = WorkspaceStore(dataRoot: root)
    await store.loadMemories()
    store.openSettings(.memories)
    return store
  }

  func testCancelBlocksUnderlyingCommandsAndPreservesAllDrafts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = await makeStore(root)
    XCTAssertTrue(store.addMemory("保留这条记忆"))
    store.memoryDraft = "尚未添加的草稿"
    let before = try Data(contentsOf: root.appendingPathComponent("memories.json"))
    store.requestMemoryDeletion(store.memoryPreferences.items[0].id)
    let request = try XCTUnwrap(store.memoryDeletion)
    XCTAssertEqual(request.kind, .single)
    XCTAssertTrue(store.hasSettingsConfirmation)
    store.requestMemoryDeletion()
    XCTAssertEqual(store.memoryDeletion, request)
    for command in DesktopCommand.all { XCTAssertFalse(store.commandEnabled(command.id), command.id) }
    XCTAssertFalse(store.handleWorkspaceShortcut(try XCTUnwrap(ShortcutBinding("⌘F"))))
    store.openSettings(.general)
    store.closeSettings()
    store.setOverlay(.commands, presented: true)
    XCTAssertEqual(store.settingsPage, .memories)
    XCTAssertEqual(store.destination, .settings)
    XCTAssertNil(store.presentedOverlay)
    store.dismissMemoryDeletion()
    XCTAssertFalse(store.hasSettingsConfirmation)
    XCTAssertEqual(store.memoryDraft, "尚未添加的草稿")
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("memories.json")), before)
  }

  func testSingleDeletionPersistsAndRemovesOnlyItsModelContext() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = await makeStore(root)
    XCTAssertTrue(store.addMemory("删除的记忆"))
    XCTAssertTrue(store.addMemory("保留的记忆"))
    store.requestMemoryDeletion(store.memoryPreferences.items[0].id)
    await store.confirmMemoryDeletion()
    XCTAssertNil(store.memoryDeletion)
    XCTAssertFalse(store.deletingMemories)
    XCTAssertFalse(store.systemInstructions.contains("删除的记忆"))
    XCTAssertTrue(store.systemInstructions.contains("保留的记忆"))
    XCTAssertEqual(try MemoryStorage.load(root: root).items.map(\.text), ["保留的记忆"])
  }

  func testFailedClearRetainsDialogAndRetryProtectsNewRecords() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = await makeStore(root)
    XCTAssertTrue(store.addMemory("one"))
    XCTAssertTrue(store.addMemory("two"))
    store.requestMemoryDeletion()
    let request = try XCTUnwrap(store.memoryDeletion)
    let before = store.memoryPreferences
    let file = root.appendingPathComponent("memories.json")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    await store.confirmMemoryDeletion()
    XCTAssertEqual(store.memoryDeletion, request)
    XCTAssertNotNil(store.memoryDeletionError)
    XCTAssertEqual(store.memoryPreferences, before)
    XCTAssertFalse(store.deletingMemories)
    try FileManager.default.removeItem(at: file)
    store.memoryPreferences.items.append(SavedMemory(text: "Arrived after confirmation opened"))
    await store.confirmMemoryDeletion()
    XCTAssertNil(store.memoryDeletion)
    XCTAssertNil(store.memoryDeletionError)
    XCTAssertEqual(try MemoryStorage.load(root: root).items.map(\.text), ["Arrived after confirmation opened"])
  }

  func testChangedRecordsAreNotDeletedUsingOldConfirmation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = await makeStore(root)
    XCTAssertTrue(store.addMemory("Original"))
    let id = store.memoryPreferences.items[0].id
    store.requestMemoryDeletion(id)
    XCTAssertTrue(store.updateMemory(id, text: "Changed"))
    await store.confirmMemoryDeletion()
    XCTAssertNotNil(store.memoryDeletion)
    XCTAssertTrue(store.memoryDeletionError?.contains("已变化") == true)
    XCTAssertEqual(try MemoryStorage.load(root: root).items.first?.text, "Changed")
    store.dismissMemoryDeletion()
    store.requestMemoryDeletion(id)
    await store.confirmMemoryDeletion()
    XCTAssertTrue(try MemoryStorage.load(root: root).items.isEmpty)
  }

  func testUnavailableAndBusyStatesCannotStartOrDuplicateDeletion() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = await makeStore(root)
    store.requestMemoryDeletion()
    XCTAssertNil(store.memoryDeletion)
    XCTAssertTrue(store.addMemory("one"))
    store.requestMemoryDeletion(UUID())
    XCTAssertNil(store.memoryDeletion)
    store.memoriesLoaded = false
    store.requestMemoryDeletion()
    XCTAssertNil(store.memoryDeletion)
    store.memoriesLoaded = true
    store.settingsPage = .general
    store.requestMemoryDeletion()
    XCTAssertNil(store.memoryDeletion)
    store.settingsPage = .memories
    store.requestMemoryDeletion()
    store.deletingMemories = true
    store.dismissMemoryDeletion()
    await store.confirmMemoryDeletion()
    XCTAssertNotNil(store.memoryDeletion)
    XCTAssertEqual(store.memoryPreferences.items.count, 1)
    store.deletingMemories = false
    store.memoriesLoaded = false
    await store.confirmMemoryDeletion()
    XCTAssertNotNil(store.memoryDeletionError)
    XCTAssertEqual(store.memoryPreferences.items.count, 1)
  }
}
