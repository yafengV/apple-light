import XCTest
@testable import ShipiOS

@MainActor final class SharedManagedWorktreeForkTests: XCTestCase {
  private func fixture() async throws -> (WorkspaceStore, URL, URL, WorkspaceTask) {
    let root = GitBranchService.canonicalRoot(FileManager.default.temporaryDirectory
      .appendingPathComponent("shared-worktree-\(UUID())"))
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
    let id = UUID().uuidString
    let snapshot = try await GitBranchService.snapshot(at: source)
    let environment = ManagedEnvironmentSnapshot(fileName: "environment.toml", name: "Shared",
      disabled: false, setupScript: "printf 'setup\\n' >> setup-count", setupPlatforms: .init(),
      cleanupScript: "printf 'cleanup\\n' >> cleanup-count", cleanupPlatforms: .init(), actions: [])
    let created = await store.createManagedWorktree(snapshot: snapshot, branch: nil,
      taskID: id, environment: environment)
    let record = try XCTUnwrap(created, store.worktreeError ?? "")
    try await store.runManagedWorktreeSetup(record)
    let run = AgentRun(id: UUID().uuidString, kind: "chat", project: record.path,
      status: "succeeded", createdAt: 1, updatedAt: 2, request: .null,
      result: .object(["response": .string("completed reply")]))
    let task = WorkspaceTask(id: id, project: record.path, title: "Owner", runIDs: [run.id])
    store.library.tasks = [task]
    store.library.chatRuns = [run]
    store.library.notes[run.id] = "completed prompt"
    store.library.drafts[id] = "owner draft"
    XCTAssertTrue(store.saveLibrary())
    return (store, root, source, task)
  }

  private func write(_ text: String, _ url: URL) throws { try Data(text.utf8).write(to: url) }

  func testSameCheckoutForkPreservesRunningSourceAndSharesOneDurableCheckout() async throws {
    let (store, _, source, owner) = try await fixture()
    let target = URL(fileURLWithPath: owner.project)
    try write("staged\n", target.appendingPathComponent("tracked"))
    _ = try await GitReviewService.checked(["add", "tracked"], at: target)
    try write("working\n", target.appendingPathComponent("tracked"))
    try write("untracked\n", target.appendingPathComponent("extra"))
    store.library.tasks[0].runIDs.append("active")
    store.library.chatRuns.append(.init(id: "active", kind: "chat", project: owner.project,
      status: "running", createdAt: 3, updatedAt: 4, request: .null, result: .null))
    store.library.unreadTasks.insert(owner.id)
    let before = try await GitReviewService.checked(["status", "--porcelain=v1", "-z"], at: target)
    XCTAssertTrue(store.canForkTaskWindow(owner.id))
    let child = try store.forkTaskWindowConversation(owner.id)
    let nested = try store.forkTaskWindowConversation(child.id)
    XCTAssertEqual(child.project, owner.project)
    XCTAssertEqual(nested.project, owner.project)
    XCTAssertEqual(store.library.managedWorktrees.count, 1)
    XCTAssertEqual(store.managedWorktreeCount, 1)
    XCTAssertEqual(store.library.managedTasks(for: store.library.managedWorktrees[0]).count, 3)
    XCTAssertEqual(store.library.sidebarProject(for: child), source.path)
    XCTAssertEqual(store.taskMenuForkDestination(child), "分叉到相同工作树")
    XCTAssertEqual(store.library.chatContext(taskID: child.id).map(\.content),
      ["completed prompt", "completed reply"])
    XCTAssertEqual(store.library.drafts[owner.id], "owner draft")
    XCTAssertTrue(store.library.unreadTasks.contains(owner.id))
    XCTAssertEqual(store.activeRun(taskID: owner.id)?.id, "active")
    XCTAssertNil(store.activeRun(taskID: child.id))
    let after = try await GitReviewService.checked(["status", "--porcelain=v1", "-z"], at: target)
    XCTAssertEqual(after, before)
    XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("setup-count")), "setup\n")
    let saved = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    XCTAssertEqual(saved.managedWorktree(forTaskID: nested.id)?.taskID, owner.id)
    XCTAssertEqual(saved.managedTasks(for: saved.managedWorktrees[0]).count, 3)
    await store.shutdown()
  }

  func testFailedForkSaveDoesNotPublishMembershipOrConsumeSourceCommand() async throws {
    let (store, _, _, owner) = try await fixture()
    store.setTaskWindowDraft("/fork", taskID: owner.id)
    let file = store.dataRoot.appendingPathComponent("workspace.json")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    XCTAssertThrowsError(try store.forkTaskWindowConversation(owner.id, consumeCommand: true))
    XCTAssertEqual(store.library.tasks.map(\.id), [owner.id])
    XCTAssertNil(store.library.managedWorktrees[0].sharedTaskIDs)
    XCTAssertTrue(store.library.forkRuns.isEmpty)
    XCTAssertEqual(store.taskWindowDraft(owner.id), "/fork")
    try FileManager.default.removeItem(at: file)
    let child = try store.forkTaskWindowConversation(owner.id, consumeCommand: true)
    XCTAssertEqual(store.taskWindowDraft(owner.id), "")
    XCTAssertEqual(store.library.managedWorktree(forTaskID: child.id)?.taskID, owner.id)
    await store.shutdown()
  }

  func testLastArchivePrunesSharedSnapshotAndEitherTaskCanRestoreAfterCreatorDeletion() async throws {
    let (store, root, source, owner) = try await fixture()
    let child = try store.forkTaskWindowConversation(owner.id)
    let target = URL(fileURLWithPath: owner.project)
    try write("staged\n", target.appendingPathComponent("tracked"))
    _ = try await GitReviewService.checked(["add", "tracked"], at: target)
    try write("working\n", target.appendingPathComponent("tracked"))
    try write("untracked\n", target.appendingPathComponent("extra"))
    try write("ignored\n", target.appendingPathComponent("ignored-local"))
    await store.archiveTask(owner.id)
    await store.managedArchiveCleanupTask?.value
    XCTAssertTrue(FileManager.default.fileExists(atPath: owner.project))
    XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent("cleanup-count").path))
    await store.archiveTask(child.id)
    await store.managedArchiveCleanupTask?.value
    XCTAssertFalse(FileManager.default.fileExists(atPath: owner.project))
    XCTAssertEqual(store.library.managedWorktrees[0].archivedPruned, true)
    XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("cleanup-count")), "cleanup\n")
    XCTAssertTrue(store.deleteArchivedTasks([owner.id]), store.archivedTaskDeletionError ?? "")
    XCTAssertEqual(store.library.managedWorktrees[0].taskID, owner.id)
    XCTAssertTrue(store.library.pendingManagedWorktreeDeletions.isEmpty)
    await store.shutdown()
    let reopened = WorkspaceStore(dataRoot: root.appendingPathComponent("data"))
    await reopened.restore()
    let restored = await reopened.restoreManagedArchiveIfNeeded(child.id)
    XCTAssertTrue(restored, reopened.archivedTaskDeletionError ?? "")
    XCTAssertTrue(reopened.restoreArchivedTask(child.id))
    XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("tracked")), "working\n")
    let index = try await GitReviewService.checked(["show", ":tracked"], at: target)
    XCTAssertEqual(index, "staged\n")
    XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("extra")), "untracked\n")
    XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("ignored-local")), "ignored\n")
    let refs = try await GitReviewService.checked(["for-each-ref", "refs/shipios/managed-archive"], at: source)
    XCTAssertTrue(refs.isEmpty)
    XCTAssertEqual(reopened.library.sidebarProject(for: child), source.path)
    await reopened.shutdown()
  }

  func testDeletingCreatorKeepsSharedCheckoutUntilLastTaskDeletion() async throws {
    let (store, _, source, owner) = try await fixture()
    let child = try store.forkTaskWindowConversation(owner.id)
    store.requestTaskDeletion(owner.id)
    await store.confirmArchiveDeletion()
    XCTAssertNil(store.archivedTaskDeletionError)
    XCTAssertEqual(store.library.tasks.map(\.id), [child.id])
    XCTAssertEqual(store.library.managedWorktrees[0].taskID, owner.id)
    XCTAssertTrue(store.library.permanentWorktrees.isEmpty)
    XCTAssertTrue(store.library.pendingManagedWorktreeDeletions.isEmpty)
    let nested = try store.forkTaskWindowConversation(child.id)
    store.requestTaskDeletion(child.id)
    await store.confirmArchiveDeletion()
    XCTAssertNil(store.archivedTaskDeletionError)
    XCTAssertEqual(store.library.sidebarProject(for: nested), source.path)
    XCTAssertEqual(store.library.managedTasks(for: store.library.managedWorktrees[0]).map(\.id), [nested.id])
    try write("keep dirty\n", URL(fileURLWithPath: owner.project).appendingPathComponent("tracked"))
    store.requestTaskDeletion(nested.id)
    await store.confirmArchiveDeletion()
    XCTAssertNil(store.archivedTaskDeletionError)
    XCTAssertTrue(store.library.tasks.isEmpty)
    XCTAssertTrue(store.library.managedWorktrees.isEmpty)
    XCTAssertTrue(store.library.pendingManagedWorktreeDeletions.isEmpty)
    XCTAssertEqual(store.library.permanentWorktrees.map(\.path), [owner.project])
    XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: owner.project)
      .appendingPathComponent("tracked")), "keep dirty\n")
    await store.shutdown()
  }

  func testPrunedSharedResourcesAreReleasedOnlyWithLastArchivedTask() async throws {
    let (store, _, source, owner) = try await fixture()
    let child = try store.forkTaskWindowConversation(owner.id)
    try write("dirty\n", URL(fileURLWithPath: owner.project).appendingPathComponent("tracked"))
    await store.archiveTask(owner.id)
    await store.managedArchiveCleanupTask?.value
    await store.archiveTask(child.id)
    await store.managedArchiveCleanupTask?.value
    let ref = "refs/shipios/managed-archive/" + owner.id
    XCTAssertTrue(store.deleteArchivedTasks([owner.id]))
    let retained = try await GitReviewService.checked(["rev-parse", "--verify", ref], at: source)
    XCTAssertFalse(retained.isEmpty)
    XCTAssertTrue(store.deleteArchivedTasks([child.id]))
    await store.managedDeletionCleanupTask?.value
    XCTAssertTrue(store.library.managedWorktrees.isEmpty)
    XCTAssertTrue(store.library.pendingManagedWorktreeDeletions.isEmpty)
    let refs = try await GitReviewService.checked(["for-each-ref", "refs/shipios"], at: source)
    XCTAssertTrue(refs.isEmpty)
    XCTAssertTrue(store.library.permanentWorktrees.isEmpty)
    await store.shutdown()
  }

  func testLimitProtectsAnyPinnedOrRunningMemberAndRestoresFromChild() async throws {
    let (store, _, _, owner) = try await fixture()
    let child = try store.forkTaskWindowConversation(owner.id)
    store.updateTask(child.id, pin: true)
    await store.pruneManagedWorktreeIfEligible(owner.id, dueToLimit: true)
    XCTAssertTrue(FileManager.default.fileExists(atPath: owner.project))
    XCTAssertTrue(store.notices.items.contains {
      $0.id == "managed-archive-" + owner.id && $0.title == "置顶任务的工作树已保留"
    })
    store.updateTask(child.id, pin: false)
    let index = try XCTUnwrap(store.library.tasks.firstIndex { $0.id == child.id })
    store.library.tasks[index].runIDs.append("running-child")
    let running = AgentRun(id: "running-child", kind: "chat", project: owner.project,
      status: "running", createdAt: 3, updatedAt: 4, request: .null, result: .null)
    store.library.chatRuns.append(running)
    await store.pruneManagedWorktreeIfEligible(owner.id, dueToLimit: true)
    XCTAssertTrue(FileManager.default.fileExists(atPath: owner.project))
    store.library.chatRuns.removeAll { $0.id == running.id }
    store.library.tasks[index].runIDs.removeAll { $0 == running.id }
    await store.pruneManagedWorktreeIfEligible(child.id, dueToLimit: true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: owner.project))
    let restored = await store.restoreManagedArchiveIfNeeded(child.id)
    XCTAssertTrue(restored, store.archivedTaskDeletionError ?? "")
    XCTAssertTrue(FileManager.default.fileExists(atPath: owner.project))
    XCTAssertFalse(store.library.tasks.contains(where: \.archived))
    XCTAssertTrue(store.canForkTaskWindow(child.id))
    await store.shutdown()
  }

  func testSharedChildCanHandoffBothWaysAndRunningSiblingBlocksFileTransfer() async throws {
    let (store, _, source, owner) = try await fixture()
    let child = try store.forkTaskWindowConversation(owner.id)
    try write("dirty\n", URL(fileURLWithPath: owner.project).appendingPathComponent("tracked"))
    let ownerIndex = try XCTUnwrap(store.library.tasks.firstIndex { $0.id == owner.id })
    store.library.tasks[ownerIndex].runIDs.append("running-owner")
    store.library.chatRuns.append(.init(id: "running-owner", kind: "chat", project: owner.project,
      status: "running", createdAt: 3, updatedAt: 4, request: .null, result: .null))
    XCTAssertFalse(store.canHandOffToLocal(child))
    let refused = await store.handOffTaskToLocal(child.id)
    XCTAssertFalse(refused)
    XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("tracked")), "initial\n")
    store.library.tasks[ownerIndex].runIDs.removeAll { $0 == "running-owner" }
    store.library.chatRuns.removeAll { $0.id == "running-owner" }
    XCTAssertTrue(store.canHandOffToLocal(child))
    let moved = await store.handOffTaskToLocal(child.id)
    XCTAssertTrue(moved, store.worktreeError ?? "")
    XCTAssertEqual(store.library.tasks.first { $0.id == child.id }?.project, source.path)
    XCTAssertEqual(store.library.tasks.first { $0.id == owner.id }?.project, owner.project)
    XCTAssertNil(store.library.managedWorktrees[0].pendingHandoff)
    XCTAssertEqual(store.library.managedWorktrees[0].taskID, owner.id)
    XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("tracked")), "dirty\n")
    let returned = await store.handOffTaskToWorktree(child.id)
    XCTAssertTrue(returned, store.worktreeError ?? "")
    XCTAssertEqual(store.library.tasks.first { $0.id == child.id }?.project, owner.project)
    XCTAssertEqual(store.library.managedWorktrees.count, 1)
    XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("tracked")), "initial\n")
    XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: owner.project)
      .appendingPathComponent("tracked")), "dirty\n")
    await store.shutdown()
  }

  func testSharedHandoffRecoveryMovesSnapshotActorAfterRestart() async throws {
    let (store, root, source, owner) = try await fixture()
    let child = try store.forkTaskWindowConversation(owner.id)
    let target = URL(fileURLWithPath: owner.project)
    try write("staged\n", target.appendingPathComponent("tracked"))
    _ = try await GitReviewService.checked(["add", "tracked"], at: target)
    try write("working\n", target.appendingPathComponent("tracked"))
    let snapshot = try await HandoffGitState.capture(taskID: child.id,
      source: target, target: source, dataRoot: store.dataRoot)
    try await HandoffGitState.apply(snapshot, dataRoot: store.dataRoot)
    store.library.managedWorktrees[0].pendingHandoff = .init(
      direction: .toLocal, snapshot: snapshot, phase: .clearing)
    XCTAssertTrue(store.saveLibrary())
    XCTAssertNil(store.pendingHandoff(forTaskID: owner.id))
    XCTAssertNotNil(store.pendingHandoff(forTaskID: child.id))
    XCTAssertFalse(store.canForkTaskWindow(owner.id))
    XCTAssertFalse(store.canForkTaskWindow(child.id))
    await store.shutdown()
    let reopened = WorkspaceStore(dataRoot: root.appendingPathComponent("data"))
    await reopened.restore()
    await reopened.pendingHandoffRecoveryTask?.value
    XCTAssertNil(reopened.library.managedWorktrees[0].pendingHandoff)
    XCTAssertEqual(reopened.library.tasks.first { $0.id == owner.id }?.project, owner.project)
    XCTAssertEqual(reopened.library.tasks.first { $0.id == child.id }?.project, source.path)
    XCTAssertEqual(reopened.library.managedWorktrees[0].taskID, owner.id)
    XCTAssertTrue(reopened.notices.items.contains {
      $0.id == "handoff-resume-" + child.id && $0.level == .success && $0.taskID == child.id
    })
    XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("tracked")), "working\n")
    let index = try await GitReviewService.checked(["show", ":tracked"], at: source)
    XCTAssertEqual(index, "staged\n")
    XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("tracked")), "initial\n")
    await reopened.shutdown()
  }

  func testCleanupReservationPreventsDeletionAndNavigationDuringSnapshot() async throws {
    let (store, _, source, owner) = try await fixture()
    let child = try store.forkTaskWindowConversation(owner.id)
    store.library.managedWorktrees[0].environment?.cleanupScript =
      "printf 'started' > cleanup-started; sleep 2"
    for index in store.library.tasks.indices { store.library.tasks[index].archived = true }
    XCTAssertTrue(store.saveLibrary())
    store.scheduleManagedArchiveCleanup(child.id)
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    while !FileManager.default.fileExists(atPath: source.appendingPathComponent("cleanup-started").path) {
      guard ContinuousClock.now < deadline else { throw AgentFailure(message: "Cleanup fixture did not start") }
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTAssertTrue(store.managedTaskPreparing)
    XCTAssertTrue(store.busy)
    XCTAssertFalse(store.canMutateArchive)
    XCTAssertFalse(store.canSelectTask(child))
    XCTAssertFalse(store.deleteArchivedTasks([owner.id, child.id]))
    XCTAssertEqual(store.library.tasks.count, 2)
    XCTAssertEqual(store.library.managedWorktrees.count, 1)
    await store.managedArchiveCleanupTask?.value
    XCTAssertFalse(store.managedTaskPreparing)
    XCTAssertFalse(store.busy)
    XCTAssertFalse(FileManager.default.fileExists(atPath: owner.project))
    let restored = await store.restoreManagedArchiveIfNeeded(child.id)
    XCTAssertTrue(restored, store.archivedTaskDeletionError ?? "")
    await store.shutdown()
  }

  func testMainWindowForkUsesSameMembershipAndOldRecordsDecodeWithoutMembers() async throws {
    let (store, _, _, owner) = try await fixture()
    await store.open(URL(fileURLWithPath: owner.project))
    store.selectTask(try XCTUnwrap(store.library.tasks.first { $0.id == owner.id }))
    XCTAssertTrue(store.canForkConversation)
    let child = try XCTUnwrap(store.forkConversation(), store.error ?? "")
    XCTAssertEqual(store.selectedTask?.id, child.id)
    XCTAssertEqual(store.currentProjectKey, owner.project)
    XCTAssertEqual(store.library.managedWorktree(forTaskID: child.id)?.taskID, owner.id)
    var legacy = store.library.managedWorktrees[0]
    legacy.sharedTaskIDs = nil
    let decoded = try JSONDecoder().decode(ManagedWorktree.self, from: JSONEncoder().encode(legacy))
    XCTAssertEqual(decoded.associatedTaskIDs, [owner.id])
    await store.shutdown()
  }
}
