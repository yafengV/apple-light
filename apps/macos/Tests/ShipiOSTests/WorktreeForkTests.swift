import XCTest
@testable import ShipiOS

@MainActor final class WorktreeForkTests: XCTestCase {
  private func fixture() async throws -> (WorkspaceStore, URL, URL, String) {
    let root = GitBranchService.canonicalRoot(FileManager.default.temporaryDirectory
      .appendingPathComponent("worktree-fork-\(UUID())"))
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    _ = try await GitReviewService.checked(["init", "-q"], at: source)
    _ = try await GitReviewService.checked(["config", "user.name", "Fixture"], at: source)
    _ = try await GitReviewService.checked(["config", "user.email", "fixture@example.invalid"], at: source)
    try write("initial\n", source.appendingPathComponent("tracked"))
    try write("ignored-*\n", source.appendingPathComponent(".gitignore"))
    _ = try await GitReviewService.checked(["add", "."], at: source)
    _ = try await GitReviewService.checked(["commit", "-qm", "Initial"], at: source)
    var repo = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { repo.deleteLastPathComponent() }
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("data"),
      agentExecutable: repo.appendingPathComponent("target/debug/shipios-agent"))
    await store.restore()
    store.library.visit(source.path)
    store.library.newTaskEnvironmentSelections[source.path] = WorktreeEnvironmentChoice.none
    let id = UUID().uuidString
    let run = AgentRun(id: "finished", kind: "chat", project: source.path, status: "succeeded",
      createdAt: 1, updatedAt: 2, request: .null, result: .object(["response": .string("saved reply")]))
    store.library.tasks = [.init(id: id, project: source.path, title: "Source", runIDs: [run.id])]
    store.library.chatRuns = [run]
    store.library.notes[run.id] = "saved prompt"
    store.library.drafts[id] = "source draft"
    XCTAssertTrue(store.saveLibrary())
    return (store, root, source, id)
  }

  private func write(_ text: String, _ url: URL) throws { try Data(text.utf8).write(to: url) }

  func testForkCopiesIndexWorkingFilesAndFixedHistoryWithoutMovingSource() async throws {
    let (store, _, source, id) = try await fixture()
    try write("staged\n", source.appendingPathComponent("tracked"))
    _ = try await GitReviewService.checked(["add", "tracked"], at: source)
    try write("working\n", source.appendingPathComponent("tracked"))
    try write("untracked\n", source.appendingPathComponent("extra"))
    try write("ignored-copy\n", source.appendingPathComponent(".worktreeinclude"))
    try write("included\n", source.appendingPathComponent("ignored-copy"))
    try write("private\n", source.appendingPathComponent("ignored-private"))
    store.library.tasks[0].runIDs.append("active")
    store.library.chatRuns.append(.init(id: "active", kind: "chat", project: source.path,
      status: "running", createdAt: 3, updatedAt: 4, request: .null, result: .null))
    store.library.unreadTasks.insert(id)
    let before = try await GitReviewService.checked(["status", "--porcelain=v1", "-z"], at: source)
    let index = try await GitReviewService.checked(["show", ":tracked"], at: source)
    let stashList = try await GitReviewService.checked(["stash", "list"], at: source)
    let created = await store.forkTaskToNewWorktree(id, openTask: false)
    let fork = try XCTUnwrap(created, store.error ?? "")
    let record = try XCTUnwrap(store.library.managedWorktrees.first { $0.taskID == fork.id })
    let target = URL(fileURLWithPath: record.path)
    XCTAssertTrue(record.ready)
    XCTAssertEqual(record.setupCompleted, true)
    XCTAssertEqual(record.sourceChangesApplied, true)
    XCTAssertNil(record.pendingForkSourceTaskID)
    XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("tracked")), "working\n")
    let targetIndex = try await GitReviewService.checked(["show", ":tracked"], at: target)
    XCTAssertEqual(targetIndex, index)
    XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("extra")), "untracked\n")
    XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("ignored-copy")), "included\n")
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("ignored-private").path))
    let after = try await GitReviewService.checked(["status", "--porcelain=v1", "-z"], at: source)
    let afterStash = try await GitReviewService.checked(["stash", "list"], at: source)
    XCTAssertEqual(after, before)
    XCTAssertEqual(afterStash, stashList)
    XCTAssertEqual(store.library.tasks.first { $0.id == id }?.project, source.path)
    XCTAssertEqual(store.library.drafts[id], "source draft")
    XCTAssertTrue(store.library.unreadTasks.contains(id))
    XCTAssertEqual(store.activeRun(taskID: id)?.id, "active")
    XCTAssertEqual(store.taskWindowRuns(fork.id).map(\.project), [record.path])
    XCTAssertEqual(store.library.chatContext(taskID: fork.id).map(\.content), ["saved prompt", "saved reply"])
    XCTAssertEqual(fork.forkOrigin?.runID, "finished")
    let saved = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    XCTAssertEqual(saved.tasks.first?.project, record.path)
    XCTAssertNil(saved.managedWorktrees.first?.pendingForkSourceTaskID)
    await store.shutdown()
  }

  func testFailedAtomicSaveCreatesNoCheckoutAndCleansProtectedSnapshots() async throws {
    let (store, _, source, id) = try await fixture()
    try write("dirty\n", source.appendingPathComponent("tracked"))
    try write("copy\n", source.appendingPathComponent("extra"))
    let workspace = store.dataRoot.appendingPathComponent("workspace.json")
    try FileManager.default.removeItem(at: workspace)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let failed = await store.forkTaskToNewWorktree(id, openTask: false)
    XCTAssertNil(failed)
    XCTAssertEqual(store.library.tasks.map(\.id), [id])
    XCTAssertTrue(store.library.managedWorktrees.isEmpty)
    let refs = try await GitReviewService.checked(["for-each-ref", "refs/shipios/managed-worktrees"], at: source)
    XCTAssertTrue(refs.isEmpty)
    let worktrees = try await GitReviewService.checked(["worktree", "list", "--porcelain"], at: source)
    let paths = worktrees.components(separatedBy: "\n").filter { $0.hasPrefix("worktree ") }
      .map { GitBranchService.canonicalRoot(URL(fileURLWithPath: String($0.dropFirst(9)))) }
    XCTAssertEqual(paths, [GitBranchService.canonicalRoot(source)])
    XCTAssertFalse(store.managedTaskPreparing)
    XCTAssertNil(store.taskMenuForkingID)
    try FileManager.default.removeItem(at: workspace)
    let created = await store.forkTaskToNewWorktree(id, openTask: false)
    XCTAssertNotNil(created, store.error ?? "")
    await store.shutdown()
  }

  func testSetupFailureResumesSameForkAfterRestartWithFrozenEnvironmentAndFiles() async throws {
    let (store, root, source, id) = try await fixture()
    store.library.newTaskEnvironmentSelections[source.path] = WorktreeEnvironmentChoice.legacy
    store.library.profiles[source.path] = BuildProfile(worktreeSetupScript:
      "printf 'attempt\n' >> attempts; test -f '\(root.path)/allow-setup'")
    try write("captured\n", source.appendingPathComponent("extra"))
    let failed = await store.forkTaskToNewWorktree(id, openTask: false)
    XCTAssertNil(failed)
    let record = try XCTUnwrap(store.library.managedWorktrees.first)
    let fork = try XCTUnwrap(store.library.tasks.first { $0.id == record.taskID })
    XCTAssertEqual(record.pendingForkSourceTaskID, id)
    XCTAssertTrue(record.ready)
    XCTAssertEqual(record.sourceChangesApplied, true)
    XCTAssertNotEqual(record.setupCompleted, true)
    XCTAssertFalse(store.canStartChat(taskID: fork.id))
    XCTAssertFalse(store.canHandOffToLocal(fork))
    XCTAssertFalse(store.canForkTaskToNewWorktree(fork.id))
    try write("changed later\n", source.appendingPathComponent("extra"))
    store.library.profiles[source.path]?.worktreeSetupScript = "exit 17"
    XCTAssertTrue(store.saveLibrary())
    await store.shutdown()
    try write("allowed", root.appendingPathComponent("allow-setup"))
    var repo = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { repo.deleteLastPathComponent() }
    let reopened = WorkspaceStore(dataRoot: store.dataRoot,
      agentExecutable: repo.appendingPathComponent("target/debug/shipios-agent"))
    await reopened.restore()
    let resumed = await reopened.resumeWorktreeFork(fork.id, openTask: false)
    XCTAssertEqual(resumed?.id, fork.id, reopened.error ?? "")
    XCTAssertEqual(reopened.library.managedWorktrees.count, 1)
    XCTAssertEqual(reopened.library.tasks.count, 2)
    XCTAssertEqual(reopened.library.tasks.first { $0.id == fork.id }?.runIDs, fork.runIDs)
    XCTAssertNil(reopened.library.managedWorktrees.first?.pendingForkSourceTaskID)
    XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: record.path).appendingPathComponent("extra")), "captured\n")
    XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: record.path).appendingPathComponent("attempts")), "attempt\nattempt\n")
    XCTAssertTrue(reopened.canStartChat(taskID: fork.id))
    let duplicate = await reopened.resumeWorktreeFork(fork.id, openTask: false)
    XCTAssertNil(duplicate)
    await reopened.shutdown()
  }

  func testManagedSourceForkRemainsUsableAfterSourceCheckoutIsPruned() async throws {
    let (store, _, source, id) = try await fixture()
    let created = await store.forkTaskToNewWorktree(id, openTask: false)
    let first = try XCTUnwrap(created, store.error ?? "")
    let firstRecord = try XCTUnwrap(store.library.managedWorktrees.first { $0.taskID == first.id })
    try write("child change\n", URL(fileURLWithPath: first.project).appendingPathComponent("tracked"))
    let childCreated = await store.forkTaskToNewWorktree(first.id, openTask: false)
    let child = try XCTUnwrap(childCreated, store.error ?? "")
    let record = try XCTUnwrap(store.library.managedWorktrees.first { $0.taskID == child.id })
    XCTAssertEqual(record.source, source.path)
    XCTAssertNotEqual(record.path, firstRecord.path)
    store.updateTask(first.id, archive: true)
    await store.managedArchiveCleanupTask?.value
    XCTAssertFalse(FileManager.default.fileExists(atPath: firstRecord.path))
    XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: child.project).appendingPathComponent("tracked")), "child change\n")
    store.updateTask(child.id, archive: true)
    await store.managedArchiveCleanupTask?.value
    XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))
    let restored = await store.restoreManagedArchiveIfNeeded(child.id)
    XCTAssertTrue(restored, store.archivedTaskDeletionError ?? "")
    XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: record.path).appendingPathComponent("tracked")), "child change\n")
    await store.shutdown()
  }

  func testPendingCheckoutRecoversOnOpenWithOriginalSnapshotAndRejectsUnownedDirectory() async throws {
    let (store, root, source, id) = try await fixture()
    let blockedRoot = root.appendingPathComponent("blocked-root")
    try write("occupied", blockedRoot)
    store.setWorktreeRoot(blockedRoot)
    try write("fixed contents\n", source.appendingPathComponent("extra"))
    let failed = await store.forkTaskToNewWorktree(id, openTask: false)
    XCTAssertNil(failed)
    let record = try XCTUnwrap(store.library.managedWorktrees.first)
    let task = try XCTUnwrap(store.library.tasks.first { $0.id == record.taskID })
    XCTAssertFalse(record.ready)
    XCTAssertEqual(record.pendingForkSourceTaskID, id)
    XCTAssertFalse(store.canStartChat(taskID: task.id))
    try FileManager.default.removeItem(at: blockedRoot)
    let target = URL(fileURLWithPath: record.path)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try write("do not overwrite", target.appendingPathComponent("foreign"))
    let refused = await store.resumeWorktreeFork(task.id, openTask: false)
    XCTAssertNil(refused)
    XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("foreign")), "do not overwrite")
    XCTAssertFalse(store.library.managedWorktrees.first?.ready ?? true)
    try FileManager.default.removeItem(at: target)
    try write("source changed later\n", source.appendingPathComponent("extra"))
    store.library.tasks.firstIndex(where: { $0.id == id }).map { store.library.tasks[$0].runIDs.append("later") }
    store.library.chatRuns.append(.init(id: "later", kind: "chat", project: source.path,
      status: "succeeded", createdAt: 5, updatedAt: 6, request: .null, result: .null))
    let opened = await store.selectTaskAwaitingScope(task)
    XCTAssertTrue(opened, store.error ?? "")
    XCTAssertEqual(store.selectedTask?.id, task.id)
    XCTAssertEqual(store.library.managedWorktrees.count, 1)
    XCTAssertEqual(store.selectedTask?.runIDs, task.runIDs)
    XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("extra")), "fixed contents\n")
    XCTAssertNil(store.library.managedWorktrees.first?.pendingForkSourceTaskID)
    await store.shutdown()
  }

  func testProjectDefaultIgnoresMissingEditorPlaceholderButRejectsExplicitMissingSelection() async throws {
    let (store, _, source, id) = try await fixture()
    store.library.newTaskEnvironmentSelections[source.path] = nil
    store.library.profiles[source.path] = BuildProfile(environmentFileName: "environment.toml")
    let created = await store.forkTaskToNewWorktree(id, openTask: false)
    let fork = try XCTUnwrap(created, store.error ?? "")
    XCTAssertEqual(store.library.managedWorktrees.first?.environment, ManagedEnvironmentSnapshot.none)
    store.library.newTaskEnvironmentSelections[source.path] = "missing.toml"
    let missing = await store.forkTaskToNewWorktree(id, openTask: false)
    XCTAssertNil(missing)
    XCTAssertEqual(store.library.tasks.count, 2)
    XCTAssertEqual(store.library.managedWorktrees.map(\.taskID), [fork.id])
    XCTAssertTrue(store.error?.contains("所选项目环境已不可用") == true)
    await store.shutdown()
  }

  func testCompletedSetupCommitCanFinalizeAfterInterruptedLastSaveWithoutRepeatingScript() async throws {
    let (store, _, source, id) = try await fixture()
    store.library.newTaskEnvironmentSelections[source.path] = WorktreeEnvironmentChoice.legacy
    store.library.profiles[source.path] = BuildProfile(worktreeSetupScript:
      "printf 'setup\n' >> setup-count; git add setup-count; git commit -qm setup")
    let created = await store.forkTaskToNewWorktree(id, openTask: false)
    let fork = try XCTUnwrap(created, store.error ?? "")
    let index = try XCTUnwrap(store.library.managedWorktrees.firstIndex { $0.taskID == fork.id })
    let record = store.library.managedWorktrees[index]
    let target = URL(fileURLWithPath: record.path)
    let head = try await GitReviewService.checked(["rev-parse", "HEAD"], at: target)
    XCTAssertNotEqual(head.trimmingCharacters(in: .newlines), record.checkout.startingCommit)
    XCTAssertEqual(record.setupCompleted, true)
    // Reachable checkpoint: setup was persisted but clearing pending state failed.
    store.library.managedWorktrees[index].pendingForkSourceTaskID = id
    XCTAssertTrue(store.saveLibrary())
    let resumed = await store.resumeWorktreeFork(fork.id, openTask: false)
    XCTAssertEqual(resumed?.id, fork.id, store.error ?? "")
    XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("setup-count")), "setup\n")
    let finalHead = try await GitReviewService.checked(["rev-parse", "HEAD"], at: target)
    XCTAssertEqual(finalHead, head)
    XCTAssertNil(store.library.managedWorktrees[index].pendingForkSourceTaskID)
    await store.shutdown()
  }
}
