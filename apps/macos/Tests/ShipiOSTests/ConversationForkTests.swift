import XCTest

@testable import ShipiOS

final class ConversationForkTests: XCTestCase {
  private func run(_ id: String, kind: String = "chat", status: String = "succeeded") -> AgentRun {
    AgentRun(
      id: id, kind: kind, project: "/fixture", status: status, createdAt: 100, updatedAt: 200,
      request: .object(["kind": .string(kind), "model": .string("fixture-model")]),
      result: .object(["response": .string("reply-\(id)")]))
  }

  private func library(_ runs: [AgentRun]) -> WorkspaceLibrary {
    var library = WorkspaceLibrary()
    for run in runs {
      library.attach(run, to: runs.first?.id, note: "prompt-\(run.id)")
      if run.kind == "chat" { library.chatRuns.append(run) }
    }
    return library
  }

  func testForkCopiesMixedPrefixWithUniqueIDsAndIndependentState() throws {
    let runs = [run("one"), run("build", kind: "build"), run("later")]
    var library = library(runs)
    library.drafts["one"] = "original draft"
    library.queuedMessages = [QueuedMessage(taskID: "one", text: "original queue")]
    library.tasks[0].pinned = true
    library.tasks[0].archived = true
    let original = library.tasks[0]
    let fork = try library.forkConversation(taskID: "one", through: "build", availableRuns: runs)
    XCTAssertEqual(library.tasks.first { $0.id == "one" }, original)
    XCTAssertEqual(fork.runIDs.count, 2)
    XCTAssertTrue(Set(fork.runIDs).isDisjoint(with: Set(runs.map(\.id))))
    XCTAssertFalse(fork.pinned)
    XCTAssertFalse(fork.archived)
    XCTAssertEqual(fork.forkOrigin, ConversationForkOrigin(taskID: "one", runID: "build"))
    XCTAssertEqual(library.forkRuns.map(\.kind), ["chat", "build"])
    XCTAssertEqual(library.forkRuns.map(\.result), Array(runs.prefix(2)).map(\.result))
    XCTAssertEqual(library.forkRunOrigins[fork.runIDs.last!], "build")
    XCTAssertEqual(library.notes[fork.runIDs[0]], "prompt-one")
    XCTAssertEqual(library.task(containing: "one")?.id, "one")
    XCTAssertEqual(library.task(containing: fork.runIDs[0])?.id, fork.id)
    XCTAssertEqual(library.drafts["one"], "original draft")
    XCTAssertNil(library.drafts[fork.id])
    XCTAssertEqual(library.queuedMessages.map(\.taskID), ["one"])
  }

  func testRunningTurnIsExcludedAndCannotBeExplicitForkPoint() throws {
    let runs = [run("done"), run("active", status: "running")]
    var library = library(runs)
    let fork = try library.forkConversation(taskID: "done", availableRuns: runs)
    XCTAssertEqual(fork.runIDs.count, 1)
    XCTAssertFalse(library.forkRuns.contains(where: \.isActive))
    let before = try JSONEncoder().encode(library)
    XCTAssertThrowsError(try library.forkConversation(taskID: "done", through: "active", availableRuns: runs))
    XCTAssertEqual(try JSONDecoder().decode(WorkspaceLibrary.self, from: before).tasks, library.tasks)
    XCTAssertEqual(library.forkRuns.count, 1)
  }

  func testMissingForeignOrUnknownHistoryCannotPartiallyCreateFork() throws {
    let runs = [run("one"), run("two")]
    var library = library(runs)
    for available in [Array(runs.prefix(1)), []] {
      XCTAssertThrowsError(try library.forkConversation(taskID: "one", availableRuns: available))
      XCTAssertEqual(library.tasks.count, 1)
      XCTAssertTrue(library.forkRuns.isEmpty)
    }
    let foreign = AgentRun(
      id: "two", kind: "chat", project: "/other", status: "succeeded", createdAt: 0,
      updatedAt: 0, request: .null, result: nil)
    XCTAssertThrowsError(try library.forkConversation(taskID: "one", availableRuns: [runs[0], foreign]))
    XCTAssertThrowsError(try library.forkConversation(taskID: "one", through: "unknown", availableRuns: runs))
    XCTAssertEqual(library.tasks.count, 1)
    XCTAssertTrue(library.forkRuns.isEmpty)
  }

  func testNestedForkPersistsAndContextExcludesLaterSourceTurns() throws {
    let runs = [run("one"), run("local", kind: "doctor"), run("two"), run("later")]
    var library = library(runs)
    let fork = try library.forkConversation(taskID: "one", through: "two", availableRuns: runs)
    let nested = try library.forkConversation(taskID: fork.id, availableRuns: library.forkRuns)
    let restored = try JSONDecoder().decode(WorkspaceLibrary.self, from: JSONEncoder().encode(library))
    XCTAssertEqual(restored.chatContext(taskID: nested.id), [
      ChatMessage(role: "user", content: "prompt-one"),
      ChatMessage(role: "assistant", content: "reply-one"),
      ChatMessage(role: "user", content: "prompt-two"),
      ChatMessage(role: "assistant", content: "reply-two"),
    ])
    XCTAssertEqual(restored.forkRunOrigins[nested.runIDs[1]], "local")
    XCTAssertEqual(restored.tasks.first?.forkOrigin?.taskID, fork.id)
    XCTAssertEqual(restored.localRuns.count, 9)
    var reconciled = restored
    reconciled.reconcile(runs + restored.forkRuns, project: "/fixture")
    XCTAssertEqual(reconciled.tasks.count, 3)
  }

  func testLegacyLibraryDecodesWithoutForkMetadata() throws {
    let data = Data(#"{"tasks":[{"id":"old","project":"/fixture","title":"Old","runIDs":["old"],"pinned":false,"archived":false}]}"#.utf8)
    let restored = try JSONDecoder().decode(WorkspaceLibrary.self, from: data)
    XCTAssertNil(restored.tasks[0].forkOrigin)
    XCTAssertTrue(restored.forkRuns.isEmpty)
    XCTAssertTrue(restored.forkRunOrigins.isEmpty)
  }

  @MainActor func testStoreForkPreservesDraftNavigationAndOriginalActiveRun() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    let runs = [run("done"), run("active", status: "running")]
    store.project = URL(fileURLWithPath: "/fixture")
    store.connected = true
    store.runs = runs
    store.library = library(runs)
    store.selection = "active"
    store.draft = "do not replace"
    let fork = try XCTUnwrap(store.forkConversation())
    XCTAssertEqual(store.selectedTask?.id, fork.id)
    XCTAssertEqual(store.activeRun?.id, "active")
    XCTAssertEqual(store.library.drafts["done"], "do not replace")
    XCTAssertEqual(store.draft, "")
    XCTAssertEqual(store.navigationBack.last?.run, "active")
    let persisted = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    XCTAssertEqual(persisted.rememberedSelection(project: "/fixture"), fork.runIDs.last)
    XCTAssertEqual(persisted.forkRuns.count, 1)
  }

  @MainActor func testFailedSaveDoesNotSwitchOrMutateLibrary() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("not a directory".utf8).write(to: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.project = URL(fileURLWithPath: "/fixture")
    store.runs = [run("one")]
    store.library = library(store.runs)
    store.selection = "one"
    store.library.drafts["one"] = "/fork"
    XCTAssertTrue(store.handleComposerCommand())
    XCTAssertEqual(store.selection, "one")
    XCTAssertEqual(store.draft, "/fork")
    XCTAssertEqual(store.library.tasks.count, 1)
    XCTAssertTrue(store.library.forkRuns.isEmpty)
    XCTAssertTrue(store.navigationBack.isEmpty)
    XCTAssertNotNil(store.error)
  }

  @MainActor func testSlashForkConsumesOnlyCommandAndFollowupAttachesToFork() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.project = URL(fileURLWithPath: "/fixture")
    store.runs = [run("one"), run("two")]
    store.library = library(store.runs)
    store.selection = "two"
    store.draft = "/fork"
    XCTAssertTrue(store.handleComposerCommand())
    let fork = try XCTUnwrap(store.selectedTask)
    XCTAssertNotEqual(fork.id, "one")
    XCTAssertEqual(store.library.drafts["one"], "")
    let followup = run("followup")
    store.library.attach(followup, to: fork.id, note: "new branch prompt")
    store.library.chatRuns.append(followup)
    XCTAssertEqual(store.library.tasks.first { $0.id == "one" }?.runIDs, ["one", "two"])
    XCTAssertEqual(store.library.chatContext(taskID: fork.id).suffix(2), [
      ChatMessage(role: "user", content: "new branch prompt"),
      ChatMessage(role: "assistant", content: "reply-followup"),
    ])
  }
}
