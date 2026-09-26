import XCTest

@testable import ShipiOS

final class WorktreeTests: XCTestCase {
  @MainActor func testTmpAliasStaysStableAcrossCreationAndPendingRecovery() async throws {
    let (_, source) = try await fixture()
    let parent = URL(fileURLWithPath: "/private/tmp/shipios-worktree-alias-\(UUID())/worktrees")
    addTeardownBlock { try? FileManager.default.removeItem(at: parent.deletingLastPathComponent()) }
    let before = GitBranchService.canonicalRoot(parent).path
    let snapshot = try await GitBranchService.snapshot(at: source)
    let record = try await WorktreeService.plan(snapshot: snapshot, branch: nil, title: "Alias", parent: parent)
    try await WorktreeService.createOrRecover(record)
    XCTAssertEqual(GitBranchService.canonicalRoot(parent).path, before)
    try await WorktreeService.createOrRecover(record)
    // Older builds could persist the long alias before creating the directory.
    let legacy = PermanentWorktree(id: record.id, source: record.source,
      path: "/private" + record.path, commonDirectory: record.commonDirectory,
      startingCommit: record.startingCommit, startingName: record.startingName,
      createdAt: record.createdAt, title: record.title)
    let data = parent.deletingLastPathComponent().appendingPathComponent("data")
    var library = WorkspaceLibrary()
    library.permanentWorktrees = [legacy]
    try library.save(to: data.appendingPathComponent("workspace.json"))
    let store = WorkspaceStore(dataRoot: data)
    await store.restore()
    let recovered = await store.recoverWorktree(legacy.id)
    XCTAssertEqual(recovered?.path, record.path, store.worktreeError ?? "")
    XCTAssertTrue(store.library.projects.contains(record.path))
    XCTAssertFalse(store.library.projects.contains(legacy.path))
    await store.shutdown()
    let target = URL(fileURLWithPath: record.path)
    let moved = target.appendingPathExtension("moved")
    try FileManager.default.moveItem(at: target, to: moved)
    try FileManager.default.createSymbolicLink(at: target, withDestinationURL: moved)
    do { try await WorktreeService.createOrRecover(record); XCTFail("Substituted symlink accepted") }
    catch { XCTAssertTrue(error.localizedDescription.contains("符号链接")) }
  }

  private func git(_ arguments: [String], _ root: URL) async throws -> String {
    try await GitReviewService.checked(arguments, at: root)
  }
  private func write(_ value: String, _ path: URL) throws { try Data(value.utf8).write(to: path) }
  private func fixture() async throws -> (URL, URL) {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("worktree-test-\(UUID())")
    let source = base.appendingPathComponent("source project")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: base) }
    _ = try await git(["init", "-q", "-b", "main"], source)
    _ = try await git(["config", "user.name", "ShipiOS Test"], source)
    _ = try await git(["config", "user.email", "qa@example.invalid"], source)
    try write("initial\n", source.appendingPathComponent("file"))
    _ = try await git(["add", "file"], source)
    _ = try await git(["commit", "-qm", "Initial"], source)
    return (GitBranchService.canonicalRoot(base), GitBranchService.canonicalRoot(source))
  }

  func testDetachedCreationKeepsSourceChangesAndCreatesNoBranch() async throws {
    let (base, source) = try await fixture()
    try write("local change\n", source.appendingPathComponent("file"))
    try write("untracked\n", source.appendingPathComponent("local"))
    let snapshot = try await GitBranchService.snapshot(at: source)
    let plan = try await WorktreeService.plan(snapshot: snapshot, branch: nil,
      title: "Permanent", parent: base.appendingPathComponent("worktrees"))
    try await WorktreeService.createOrRecover(plan)
    let target = URL(fileURLWithPath: plan.path)
    let checkout = try await GitBranchService.snapshot(at: target)
    XCTAssertNil(checkout.currentReference)
    XCTAssertEqual(checkout.currentCommit, snapshot.currentCommit)
    XCTAssertEqual(checkout.branches.map(\.reference), snapshot.branches.map(\.reference))
    XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("file")), "initial\n")
    XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("file")), "local change\n")
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("local").path))
    let after = try await GitBranchService.snapshot(at: source)
    XCTAssertEqual(after.currentName, "main")
    XCTAssertEqual(after.changedFiles, 2)
  }

  func testManagedSourceFilesCopyOnlyUntrackedIncludedIgnoredAndOverrideIdempotently() async throws {
    let (base, source) = try await fixture()
    try write(".env\nskip.env\nignored-link\nAGENTS.override.md\n", source.appendingPathComponent(".gitignore"))
    try write(".env\nignored-link\n", source.appendingPathComponent(".worktreeinclude"))
    _ = try await git(["add", ".gitignore", ".worktreeinclude"], source)
    _ = try await git(["commit", "-qm", "Ignore configuration"], source)
    try write("included\n", source.appendingPathComponent(".env"))
    try write("excluded\n", source.appendingPathComponent("skip.env"))
    try write("override\n", source.appendingPathComponent("AGENTS.override.md"))
    try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("ignored-link"),
      withDestinationURL: source.appendingPathComponent("file"))
    let script = source.appendingPathComponent("new-script")
    try write("#!/bin/sh\n", script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let embeddedData = source.appendingPathComponent("private-data", isDirectory: true)
    try FileManager.default.createDirectory(at: embeddedData, withIntermediateDirectories: true)
    try write("internal\n", embeddedData.appendingPathComponent("workspace.json"))
    let paths = try await ManagedSourceFiles.discover(at: source, excluding: embeddedData)
    XCTAssertEqual(paths, [".env", "AGENTS.override.md", "new-script"])
    let taskID = UUID().uuidString
    let data = base.appendingPathComponent("data")
    let files = try ManagedSourceFiles.capture(paths, from: source, dataRoot: data, taskID: taskID)
    XCTAssertEqual(files.count, 3)
    let snapshot = try await GitBranchService.snapshot(at: source)
    let plan = try await WorktreeService.plan(snapshot: snapshot, branch: nil,
      title: "Managed", parent: base.appendingPathComponent("worktrees"))
    try await WorktreeService.createOrRecover(plan)
    let target = URL(fileURLWithPath: plan.path)
    try ManagedSourceFiles.install(files, dataRoot: data, taskID: taskID, target: target)
    try ManagedSourceFiles.install(files, dataRoot: data, taskID: taskID, target: target)
    XCTAssertEqual(try String(contentsOf: target.appendingPathComponent(".env")), "included\n")
    XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("AGENTS.override.md")), "override\n")
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("skip.env").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("ignored-link").path))
    let attributes = try FileManager.default.attributesOfItem(atPath:
      target.appendingPathComponent("new-script").path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
    try write("other\n", target.appendingPathComponent(".env"))
    do {
      try ManagedSourceFiles.install(files, dataRoot: data, taskID: taskID, target: target)
      XCTFail("Existing different file was overwritten")
    } catch { XCTAssertTrue(error.localizedDescription.contains("未覆盖")) }
    XCTAssertEqual(try String(contentsOf: target.appendingPathComponent(".env")), "other\n")
    ManagedSourceFiles.removeSnapshot(dataRoot: data, taskID: taskID)
  }

  func testManagedSourceFileSnapshotRejectsSymlinksAndTraversal() async throws {
    let (base, source) = try await fixture()
    let data = base.appendingPathComponent("data")
    let taskID = UUID().uuidString
    try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("link"),
      withDestinationURL: source.appendingPathComponent("file"))
    do {
      _ = try ManagedSourceFiles.capture(["link"], from: source, dataRoot: data, taskID: taskID)
      XCTFail("Symlink was copied")
    } catch { XCTAssertTrue(error.localizedDescription.contains("符号链接")) }
    do {
      _ = try ManagedSourceFiles.capture(["../file"], from: source, dataRoot: data,
        taskID: taskID)
      XCTFail("Traversal was copied")
    } catch { XCTAssertTrue(error.localizedDescription.contains("路径无效")) }
  }

  func testHandoffLocalFilesPreflightAndRemoveOnlyCapturedUnchangedFiles() async throws {
    let (base, source) = try await fixture()
    try write(".env\n", source.appendingPathComponent(".gitignore"))
    try write(".env\n", source.appendingPathComponent(".worktreeinclude"))
    _ = try await git(["add", ".gitignore", ".worktreeinclude"], source)
    _ = try await git(["commit", "-qm", "Local file policy"], source)
    try write("private\n", source.appendingPathComponent(".env"))
    try write("draft\n", source.appendingPathComponent("note"))
    let snapshot = try await GitBranchService.snapshot(at: source)
    let plan = try await WorktreeService.plan(snapshot: snapshot, branch: nil,
      title: "Move local files", parent: base.appendingPathComponent("worktrees"))
    try await WorktreeService.createOrRecover(plan)
    let target = URL(fileURLWithPath: plan.path)
    let data = base.appendingPathComponent("data")
    let taskID = UUID().uuidString
    let paths = try await ManagedSourceFiles.discover(at: source, excluding: data)
    XCTAssertEqual(paths, [".env", "note"])
    let files = try ManagedSourceFiles.capture(paths, from: source, dataRoot: data,
      taskID: taskID)
    XCTAssertTrue(ManagedSourceFiles.snapshotExists(dataRoot: data, taskID: taskID))

    try write("different\n", target.appendingPathComponent(".env"))
    XCTAssertFalse(try ManagedSourceFiles.canInstall(files, dataRoot: data,
      taskID: taskID, target: target))
    XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("note")), "draft\n")
    try FileManager.default.removeItem(at: target.appendingPathComponent(".env"))
    XCTAssertTrue(try ManagedSourceFiles.canInstall(files, dataRoot: data,
      taskID: taskID, target: target))
    try ManagedSourceFiles.install(files, dataRoot: data, taskID: taskID, target: target)

    try write("changed after capture\n", source.appendingPathComponent("note"))
    do {
      try await ManagedSourceFiles.removeCaptured(files, from: source, excluding: data)
      XCTFail("Modified source file was removed")
    } catch { XCTAssertTrue(error.localizedDescription.contains("改变")) }
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent(".env").path))
    try write("draft\n", source.appendingPathComponent("note"))
    try write("new\n", source.appendingPathComponent("late"))
    do {
      try await ManagedSourceFiles.removeCaptured(files, from: source, excluding: data)
      XCTFail("New source file was ignored")
    } catch { XCTAssertTrue(error.localizedDescription.contains("新的未跟踪")) }
    try FileManager.default.removeItem(at: source.appendingPathComponent("late"))
    try await ManagedSourceFiles.removeCaptured(files, from: source, excluding: data)
    try await ManagedSourceFiles.removeCaptured(files, from: source, excluding: data)
    XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent(".env").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent("note").path))
    XCTAssertEqual(try String(contentsOf: target.appendingPathComponent(".env")), "private\n")
    XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("note")), "draft\n")
    try ManagedSourceFiles.removeSnapshotChecked(dataRoot: data, taskID: taskID)
    XCTAssertFalse(ManagedSourceFiles.snapshotExists(dataRoot: data, taskID: taskID))
  }

  func testSelectedBranchAndStaleBranchValidation() async throws {
    let (base, source) = try await fixture()
    _ = try await git(["switch", "-c", "feature"], source)
    try write("feature\n", source.appendingPathComponent("file"))
    _ = try await git(["commit", "-qam", "Feature"], source)
    _ = try await git(["switch", "main"], source)
    let snapshot = try await GitBranchService.snapshot(at: source)
    let branch = try XCTUnwrap(snapshot.branches.first { $0.name == "feature" })
    let plan = try await WorktreeService.plan(snapshot: snapshot, branch: branch,
      title: "Feature", parent: base.appendingPathComponent("worktrees"))
    try await WorktreeService.createOrRecover(plan)
    XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: plan.path).appendingPathComponent("file")), "feature\n")
    _ = try await git(["branch", "-f", "feature", "main"], source)
    do {
      _ = try await WorktreeService.plan(snapshot: snapshot, branch: branch, title: "Stale", parent: base)
      XCTFail("Stale branch accepted")
    } catch { XCTAssertTrue(error.localizedDescription.contains("已更新")) }
  }

  func testRecoveryDoesNotResetDirtyWorktreeAndDoesNotOverwriteOtherDirectories() async throws {
    let (base, source) = try await fixture()
    let snapshot = try await GitBranchService.snapshot(at: source)
    let plan = try await WorktreeService.plan(snapshot: snapshot, branch: nil, title: "Recover", parent: base)
    try await WorktreeService.createOrRecover(plan)
    let file = URL(fileURLWithPath: plan.path).appendingPathComponent("file")
    try write("keep work\n", file)
    try await WorktreeService.createOrRecover(plan)
    XCTAssertEqual(try String(contentsOf: file), "keep work\n")
    let collision = try await WorktreeService.plan(snapshot: snapshot, branch: nil, title: "Collision", parent: base)
    try FileManager.default.createDirectory(atPath: collision.path, withIntermediateDirectories: true)
    let existing = URL(fileURLWithPath: collision.path).appendingPathComponent("file")
    try write("existing user data\n", existing)
    do { try await WorktreeService.createOrRecover(collision); XCTFail("Existing folder overwritten") }
    catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
    XCTAssertEqual(try String(contentsOf: existing), "existing user data\n")
  }

  func testManagedArchiveOnlyRemovesVerifiedCleanCheckoutAndCanRecreateIt() async throws {
    let (base, source) = try await fixture()
    let snapshot = try await GitBranchService.snapshot(at: source)
    let plan = try await WorktreeService.plan(snapshot: snapshot, branch: nil,
      title: "Managed", parent: base.appendingPathComponent("worktrees"))
    try await WorktreeService.createOrRecover(plan)
    let taskID = UUID().uuidString
    let managed = ManagedWorktree(taskID: taskID, checkout: plan)
    let target = URL(fileURLWithPath: plan.path)
    let file = target.appendingPathComponent("file")
    try write("dirty\n", file)
    let dirtyRemoved = try await WorktreeService.removeCleanManaged(managed)
    XCTAssertFalse(dirtyRemoved)
    XCTAssertEqual(try String(contentsOf: file), "dirty\n")
    try write("initial\n", file)
    try write("other\n", target.appendingPathComponent("untracked"))
    let untrackedRemoved = try await WorktreeService.removeCleanManaged(managed)
    XCTAssertFalse(untrackedRemoved)
    try FileManager.default.removeItem(at: target.appendingPathComponent("untracked"))
    try write("ignored\n", target.appendingPathComponent(".gitignore"))
    _ = try await git(["add", ".gitignore"], target)
    _ = try await git(["commit", "-qm", "Ignore cache"], target)
    try write("cache\n", target.appendingPathComponent("ignored"))
    let ignoredRemoved = try await WorktreeService.removeCleanManaged(managed)
    XCTAssertFalse(ignoredRemoved)
    try FileManager.default.removeItem(at: target.appendingPathComponent("ignored"))
    let empty = target.appendingPathComponent("empty-directory", isDirectory: true)
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
    let emptyRemoved = try await WorktreeService.removeCleanManaged(managed)
    XCTAssertFalse(emptyRemoved)
    try FileManager.default.removeItem(at: empty)
    let head = try await git(["rev-parse", "HEAD"], target)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let reference = "refs/shipios/managed-archive/\(taskID)"
    _ = try await git(["update-ref", reference, head], source)
    let cleanRemoved = try await WorktreeService.removeCleanManaged(managed)
    XCTAssertTrue(cleanRemoved)
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    let restored = PermanentWorktree(id: plan.id, source: plan.source, path: plan.path,
      commonDirectory: plan.commonDirectory, startingCommit: head,
      startingName: plan.startingName, createdAt: plan.createdAt, title: plan.title)
    try await WorktreeService.createOrRecover(restored)
    XCTAssertEqual(try String(contentsOf: file), "initial\n")
    XCTAssertEqual(try String(contentsOf: target.appendingPathComponent(".gitignore")), "ignored\n")
    _ = try await git(["update-ref", "-d", reference, head], source)
  }

  func testManagedArchiveRefusesForceRemovalWhenCheckoutChangesAfterSnapshot() async throws {
    let (base, source) = try await fixture()
    let snapshot = try await GitBranchService.snapshot(at: source)
    let plan = try await WorktreeService.plan(snapshot: snapshot, branch: nil,
      title: "Snapshot", parent: base.appendingPathComponent("worktrees"))
    try await WorktreeService.createOrRecover(plan)
    let target = URL(fileURLWithPath: plan.path)
    let file = target.appendingPathComponent("file")
    try write("captured\n", file)
    try write("extra\n", target.appendingPathComponent("untracked"))
    let taskID = UUID().uuidString
    let data = base.appendingPathComponent("data")
    let paths = try await ManagedSourceFiles.discoverAll(at: target, excluding: data)
    let files = try ManagedSourceFiles.capture(paths, from: target,
      dataRoot: data, taskID: taskID)
    let stash = try await git(["stash", "create", "snapshot"], target)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let head = try await git(["rev-parse", "HEAD"], target)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    _ = try await git(["update-ref", "refs/shipios/managed-archive/\(taskID)", head], source)
    _ = try await git(["update-ref", "refs/shipios/managed-archive-dirty/\(taskID)", stash], source)
    var managed = ManagedWorktree(taskID: taskID, checkout: plan)
    managed.archivedHead = head
    managed.archivedStashCommit = stash
    managed.archivedCopiedFiles = files
    try write("changed after capture\n", file)
    let removed = try await WorktreeService.removeSnapshottedManaged(managed, dataRoot: data)
    XCTAssertFalse(removed)
    XCTAssertEqual(try String(contentsOf: file), "changed after capture\n")
    try write("captured\n", file)
    let nowRemoved = try await WorktreeService.removeSnapshottedManaged(managed, dataRoot: data)
    XCTAssertTrue(nowRemoved)
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
  }

  @MainActor func testArchiveAndRestoreManagedTasksKeepsTrackedAndUntrackedChanges() async throws {
    let (base, source) = try await fixture()
    let data = base.appendingPathComponent("data")
    var repository = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    var store = WorkspaceStore(dataRoot: data,
      agentExecutable: repository.appendingPathComponent("target/debug/shipios-agent"))
    await store.restore()
    await store.open(source)
    XCTAssertTrue(store.connected, store.error ?? "")
    let snapshot = try await GitBranchService.snapshot(at: source)
    let cleanID = UUID().uuidString
    let cleanCreated = await store.createManagedWorktree(snapshot: snapshot,
      branch: nil, taskID: cleanID)
    let clean = try XCTUnwrap(cleanCreated, store.worktreeError ?? "")
    try write("committed in worktree\n", URL(fileURLWithPath: clean.path).appendingPathComponent("file"))
    _ = try await git(["commit", "-qam", "Worktree progress"], URL(fileURLWithPath: clean.path))
    store.library.tasks.append(WorkspaceTask(id: cleanID, project: clean.path,
      title: "Clean", runIDs: []))
    XCTAssertTrue(store.saveLibrary())
    store.updateTask(cleanID, archive: true)
    await store.managedArchiveCleanupTask?.value
    XCTAssertTrue(store.library.tasks.first { $0.id == cleanID }?.archived == true)
    XCTAssertEqual(store.library.managedWorktrees.first { $0.taskID == cleanID }?.archivedPruned, true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: clean.path))
    let protectedRef = "refs/shipios/managed-archive/\(cleanID)"
    let beforeRestore = try await LocalWorkspaceService.git(
      ["show-ref", "--verify", protectedRef], at: source)
    XCTAssertEqual(beforeRestore.status, 0)
    await store.shutdown()
    store = WorkspaceStore(dataRoot: data,
      agentExecutable: repository.appendingPathComponent("target/debug/shipios-agent"))
    await store.restore()
    XCTAssertEqual(store.library.managedWorktrees.first { $0.taskID == cleanID }?.archivedPruned, true)
    await store.restoreArchivedTaskWithFeedback(cleanID)
    XCTAssertFalse(store.library.tasks.first { $0.id == cleanID }?.archived ?? true)
    XCTAssertTrue(FileManager.default.fileExists(atPath: clean.path))
    XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: clean.path).appendingPathComponent("file")),
      "committed in worktree\n")
    let afterRestore = try await LocalWorkspaceService.git(
      ["show-ref", "--verify", protectedRef], at: source)
    XCTAssertNotEqual(afterRestore.status, 0)

    let dirtyID = UUID().uuidString
    let dirtyCreated = await store.createManagedWorktree(snapshot: snapshot,
      branch: nil, taskID: dirtyID)
    let dirty = try XCTUnwrap(dirtyCreated, store.worktreeError ?? "")
    store.library.tasks.append(WorkspaceTask(id: dirtyID, project: dirty.path,
      title: "Dirty", runIDs: []))
    XCTAssertTrue(store.saveLibrary())
    let dirtyRoot = URL(fileURLWithPath: dirty.path)
    let dirtyFile = dirtyRoot.appendingPathComponent("file")
    try write("staged\n", dirtyFile)
    _ = try await git(["add", "file"], dirtyRoot)
    try write("unsaved\n", dirtyFile)
    try write("ignored\n", dirtyRoot.appendingPathComponent(".gitignore"))
    _ = try await git(["add", ".gitignore"], dirtyRoot)
    try write("untracked\n", dirtyRoot.appendingPathComponent("untracked"))
    try write("cache\n", dirtyRoot.appendingPathComponent("ignored"))
    store.updateTask(dirtyID, archive: true)
    await store.managedArchiveCleanupTask?.value
    XCTAssertFalse(FileManager.default.fileExists(atPath: dirty.path))
    let archivedDirty = try XCTUnwrap(store.library.managedWorktrees.first { $0.taskID == dirtyID })
    XCTAssertEqual(archivedDirty.archivedPruned, true)
    XCTAssertNotNil(archivedDirty.archivedStashCommit)
    XCTAssertEqual(archivedDirty.archivedCopiedFiles?.map(\.path).sorted(),
      ["ignored", "untracked"])
    await store.shutdown()
    store = WorkspaceStore(dataRoot: data,
      agentExecutable: repository.appendingPathComponent("target/debug/shipios-agent"))
    await store.restore()
    XCTAssertEqual(store.library.managedWorktrees.first { $0.taskID == dirtyID }?.archivedPruned,
      true)
    try FileManager.default.createDirectory(at: dirtyRoot, withIntermediateDirectories: false)
    let collision = dirtyRoot.appendingPathComponent("occupied")
    try write("do not overwrite\n", collision)
    await store.restoreArchivedTaskWithFeedback(dirtyID)
    XCTAssertTrue(store.library.tasks.first { $0.id == dirtyID }?.archived == true)
    XCTAssertEqual(try String(contentsOf: collision), "do not overwrite\n")
    try FileManager.default.removeItem(at: dirtyRoot)
    await store.restoreArchivedTaskWithFeedback(dirtyID)
    XCTAssertFalse(store.library.tasks.first { $0.id == dirtyID }?.archived ?? true)
    XCTAssertEqual(try String(contentsOf: dirtyFile), "unsaved\n")
    XCTAssertEqual(try String(contentsOf: dirtyRoot.appendingPathComponent("untracked")),
      "untracked\n")
    XCTAssertEqual(try String(contentsOf: dirtyRoot.appendingPathComponent("ignored")), "cache\n")
    let restoredStatus = try await git(["status", "--short"], dirtyRoot)
    XCTAssertTrue(restoredStatus.contains("MM file"), restoredStatus)
    XCTAssertTrue(restoredStatus.contains("A  .gitignore"), restoredStatus)
    XCTAssertTrue(restoredStatus.contains("?? untracked"), restoredStatus)
    XCTAssertFalse(FileManager.default.fileExists(atPath: data
      .appendingPathComponent("ManagedSourceSnapshots").appendingPathComponent(dirtyID).path))
    let dirtyReference = try await LocalWorkspaceService.git(
      ["show-ref", "--verify", "refs/shipios/managed-archive-dirty/\(dirtyID)"], at: source)
    XCTAssertNotEqual(dirtyReference.status, 0)

    let pinnedID = UUID().uuidString
    let pinnedCreated = await store.createManagedWorktree(snapshot: snapshot,
      branch: nil, taskID: pinnedID)
    let pinned = try XCTUnwrap(pinnedCreated, store.worktreeError ?? "")
    var pinnedTask = WorkspaceTask(id: pinnedID, project: pinned.path,
      title: "Pinned", runIDs: [])
    pinnedTask.pinned = true
    store.library.tasks.append(pinnedTask)
    XCTAssertTrue(store.saveLibrary())
    store.updateTask(pinnedID, archive: true)
    await store.managedArchiveCleanupTask?.value
    XCTAssertTrue(FileManager.default.fileExists(atPath: pinned.path))
    XCTAssertNil(store.library.managedWorktrees.first { $0.taskID == pinnedID }?.archivedHead)
    await store.shutdown()
  }

  @MainActor func testManagedArchiveSaveFailureDoesNotRemoveCheckout() async throws {
    let (base, source) = try await fixture()
    let data = base.appendingPathComponent("data")
    let store = WorkspaceStore(dataRoot: data)
    await store.restore()
    store.library.visit(source.path)
    XCTAssertTrue(store.saveLibrary())
    let snapshot = try await GitBranchService.snapshot(at: source)
    let taskID = UUID().uuidString
    let created = await store.createManagedWorktree(snapshot: snapshot,
      branch: nil, taskID: taskID)
    let managed = try XCTUnwrap(created, store.worktreeError ?? "")
    store.library.tasks.append(WorkspaceTask(id: taskID, project: managed.path,
      title: "Keep", runIDs: []))
    XCTAssertTrue(store.saveLibrary())
    let workspaceFile = data.appendingPathComponent("workspace.json")
    try FileManager.default.removeItem(at: workspaceFile)
    try FileManager.default.createDirectory(at: workspaceFile, withIntermediateDirectories: true)
    store.updateTask(taskID, archive: true)
    XCTAssertNil(store.managedArchiveCleanupTask)
    XCTAssertTrue(FileManager.default.fileExists(atPath: managed.path))
    XCTAssertNil(store.library.managedWorktrees.first?.archivedHead)
    try FileManager.default.removeItem(at: workspaceFile)
    await store.shutdown()
  }

  @MainActor func testDeletingPrunedManagedTaskCleansProtectedRefsAndPrivateSnapshot() async throws {
    let (base, source) = try await fixture()
    let data = base.appendingPathComponent("data")
    var store = WorkspaceStore(dataRoot: data)
    await store.restore()
    store.library.visit(source.path)
    XCTAssertTrue(store.saveLibrary())
    let snapshot = try await GitBranchService.snapshot(at: source)
    let taskID = UUID().uuidString
    let created = await store.createManagedWorktree(snapshot: snapshot,
      branch: nil, taskID: taskID)
    let record = try XCTUnwrap(created, store.worktreeError ?? "")
    let target = URL(fileURLWithPath: record.path)
    store.library.tasks.append(WorkspaceTask(id: taskID, project: record.path,
      title: "Delete snapshot", runIDs: []))
    XCTAssertTrue(store.saveLibrary())
    try write("local edit\n", target.appendingPathComponent("file"))
    try write("private copy\n", target.appendingPathComponent("untracked"))
    store.updateTask(taskID, archive: true)
    await store.managedArchiveCleanupTask?.value
    XCTAssertEqual(store.library.managedWorktrees.first?.archivedPruned, true)
    let snapshotRoot = data.appendingPathComponent("ManagedSourceSnapshots")
      .appendingPathComponent(taskID)
    XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotRoot.path))

    store.archiveDeletion = .init(kind: .single, taskIDs: [taskID])
    await store.confirmArchiveDeletion()
    XCTAssertFalse(store.library.tasks.contains { $0.id == taskID })
    XCTAssertFalse(store.library.managedWorktrees.contains { $0.taskID == taskID })
    XCTAssertTrue(store.library.pendingManagedWorktreeDeletions.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotRoot.path))
    for reference in ["refs/shipios/managed-archive/\(taskID)",
      "refs/shipios/managed-archive-dirty/\(taskID)"] {
      let result = try await LocalWorkspaceService.git(["show-ref", "--verify", reference], at: source)
      XCTAssertNotEqual(result.status, 0)
    }
    await store.shutdown()
    store = WorkspaceStore(dataRoot: data)
    await store.restore()
    XCTAssertTrue(store.library.pendingManagedWorktreeDeletions.isEmpty)
    XCTAssertFalse(store.library.tasks.contains { $0.id == taskID })
    await store.shutdown()
  }

  @MainActor func testDeletingRetainedManagedTaskPreservesCheckoutAsPermanentProject() async throws {
    let (base, source) = try await fixture()
    let data = base.appendingPathComponent("data")
    var store = WorkspaceStore(dataRoot: data)
    await store.restore()
    store.library.visit(source.path)
    XCTAssertTrue(store.saveLibrary())
    let snapshot = try await GitBranchService.snapshot(at: source)
    let taskID = UUID().uuidString
    let created = await store.createManagedWorktree(snapshot: snapshot,
      branch: nil, taskID: taskID)
    let record = try XCTUnwrap(created, store.worktreeError ?? "")
    let target = URL(fileURLWithPath: record.path)
    let edit = target.appendingPathComponent("keep-me")
    try write("user data\n", edit)
    var task = WorkspaceTask(id: taskID, project: record.path,
      title: "Retained checkout", runIDs: [])
    task.pinned = true
    store.library.tasks.append(task)
    XCTAssertTrue(store.saveLibrary())
    store.updateTask(taskID, archive: true)
    await store.managedArchiveCleanupTask?.value
    XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    store.archiveDeletion = .init(kind: .single, taskIDs: [taskID])
    await store.confirmArchiveDeletion()
    XCTAssertNil(store.archivedTaskDeletionError)
    XCTAssertFalse(store.library.tasks.contains { $0.id == taskID })
    XCTAssertFalse(store.library.managedWorktrees.contains { $0.taskID == taskID })
    XCTAssertTrue(store.library.permanentWorktrees.contains { $0.path == record.path && $0.ready })
    XCTAssertTrue(store.library.projects.contains(record.path))
    XCTAssertEqual(store.library.projectTitle(record.path), "Retained checkout")
    XCTAssertEqual(try String(contentsOf: edit), "user data\n")
    await store.shutdown()
    store = WorkspaceStore(dataRoot: data)
    await store.restore()
    XCTAssertTrue(store.library.permanentWorktrees.contains { $0.path == record.path && $0.ready })
    XCTAssertEqual(try String(contentsOf: edit), "user data\n")
    await store.shutdown()
  }

  @MainActor func testManagedDeletionRetainsCleanupRecordUntilProtectedRefCanBeRemoved() async throws {
    let (base, source) = try await fixture()
    let data = base.appendingPathComponent("data")
    var store = WorkspaceStore(dataRoot: data)
    await store.restore()
    store.library.visit(source.path)
    XCTAssertTrue(store.saveLibrary())
    let snapshot = try await GitBranchService.snapshot(at: source)
    let taskID = UUID().uuidString
    let created = await store.createManagedWorktree(snapshot: snapshot,
      branch: nil, taskID: taskID)
    let record = try XCTUnwrap(created, store.worktreeError ?? "")
    let target = URL(fileURLWithPath: record.path)
    try write("committed progress\n", target.appendingPathComponent("file"))
    _ = try await git(["commit", "-qam", "Progress"], target)
    store.library.tasks.append(WorkspaceTask(id: taskID, project: record.path,
      title: "Retry cleanup", runIDs: []))
    XCTAssertTrue(store.saveLibrary())
    store.updateTask(taskID, archive: true)
    await store.managedArchiveCleanupTask?.value
    let archivedHead = try XCTUnwrap(store.library.managedWorktrees.first?.archivedHead)
    let reference = "refs/shipios/managed-archive/\(taskID)"
    _ = try await git(["update-ref", reference, snapshot.currentCommit!], source)
    store.archiveDeletion = .init(kind: .single, taskIDs: [taskID])
    await store.confirmArchiveDeletion()
    XCTAssertFalse(store.library.tasks.contains { $0.id == taskID })
    XCTAssertEqual(store.library.pendingManagedWorktreeDeletions.map(\.taskID), [taskID])
    let altered = try await LocalWorkspaceService.git(["rev-parse", reference], at: source)
    XCTAssertEqual(altered.text.trimmingCharacters(in: .whitespacesAndNewlines),
      snapshot.currentCommit)
    await store.shutdown()
    store = WorkspaceStore(dataRoot: data)
    await store.restore()
    XCTAssertEqual(store.library.pendingManagedWorktreeDeletions.map(\.taskID), [taskID])
    _ = try await git(["update-ref", reference, archivedHead], source)
    await store.cleanupPendingManagedWorktreeDeletions()
    XCTAssertTrue(store.library.pendingManagedWorktreeDeletions.isEmpty)
    let removed = try await LocalWorkspaceService.git(["show-ref", "--verify", reference], at: source)
    XCTAssertNotEqual(removed.status, 0)
    await store.shutdown()
  }

  @MainActor func testDeletingManagedTaskRejectsReplacedCheckout() async throws {
    let (base, source) = try await fixture()
    let data = base.appendingPathComponent("data")
    let store = WorkspaceStore(dataRoot: data)
    await store.restore()
    store.library.visit(source.path)
    XCTAssertTrue(store.saveLibrary())
    let snapshot = try await GitBranchService.snapshot(at: source)
    let taskID = UUID().uuidString
    let created = await store.createManagedWorktree(snapshot: snapshot,
      branch: nil, taskID: taskID)
    let record = try XCTUnwrap(created, store.worktreeError ?? "")
    var task = WorkspaceTask(id: taskID, project: record.path,
      title: "Do not convert", runIDs: [])
    task.pinned = true
    store.library.tasks.append(task)
    XCTAssertTrue(store.saveLibrary())
    store.updateTask(taskID, archive: true)
    await store.managedArchiveCleanupTask?.value
    let target = URL(fileURLWithPath: record.path)
    let moved = target.appendingPathExtension("moved")
    try FileManager.default.moveItem(at: target, to: moved)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    try write("unrelated\n", target.appendingPathComponent("do-not-touch"))
    store.archiveDeletion = .init(kind: .single, taskIDs: [taskID])
    await store.confirmArchiveDeletion()
    XCTAssertTrue(store.library.tasks.contains { $0.id == taskID && $0.archived })
    XCTAssertTrue(store.library.managedWorktrees.contains { $0.taskID == taskID })
    XCTAssertFalse(store.library.permanentWorktrees.contains { $0.path == record.path })
    XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("do-not-touch")),
      "unrelated\n")
    XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
    await store.shutdown()
  }

  @MainActor func testDeletingManagedTaskKeepsUnappliedSourceSnapshot() async throws {
    let (base, source) = try await fixture()
    let data = base.appendingPathComponent("data")
    let store = WorkspaceStore(dataRoot: data)
    await store.restore()
    store.library.visit(source.path)
    XCTAssertTrue(store.saveLibrary())
    let snapshot = try await GitBranchService.snapshot(at: source)
    let taskID = UUID().uuidString
    let created = await store.createManagedWorktree(snapshot: snapshot,
      branch: nil, taskID: taskID)
    let record = try XCTUnwrap(created, store.worktreeError ?? "")
    var task = WorkspaceTask(id: taskID, project: record.path,
      title: "Pending source changes", runIDs: [])
    task.pinned = true
    store.library.tasks.append(task)
    let index = try XCTUnwrap(store.library.managedWorktrees.firstIndex { $0.taskID == taskID })
    store.library.managedWorktrees[index].sourceCopiedFiles = [
      ManagedSourceFile(path: "source-only", sha256: String(repeating: "a", count: 64),
        permissions: 0o600)
    ]
    XCTAssertTrue(store.saveLibrary())
    store.updateTask(taskID, archive: true)
    await store.managedArchiveCleanupTask?.value
    store.archiveDeletion = .init(kind: .single, taskIDs: [taskID])
    await store.confirmArchiveDeletion()
    XCTAssertTrue(store.library.tasks.contains { $0.id == taskID && $0.archived })
    XCTAssertTrue(store.library.managedWorktrees.contains { $0.taskID == taskID })
    XCTAssertTrue(store.library.permanentWorktrees.isEmpty)
    XCTAssertTrue(store.archivedTaskDeletionError?.contains("来源修改") == true)
    await store.shutdown()
  }

  func testMetadataDirectoryAndChangedRootAreRejected() async throws {
    let (base, source) = try await fixture()
    let snapshot = try await GitBranchService.snapshot(at: source)
    do {
      _ = try await WorktreeService.plan(snapshot: snapshot, branch: nil, title: "Unsafe", parent: source.appendingPathComponent(".git/worktrees"))
      XCTFail("Git metadata directory accepted")
    } catch { XCTAssertTrue(error.localizedDescription.contains("元数据")) }
    let root = base.appendingPathComponent("worktrees")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let plan = try await WorktreeService.plan(snapshot: snapshot, branch: nil, title: "Moved", parent: root)
    let moved = base.appendingPathComponent("moved")
    try FileManager.default.moveItem(at: root, to: moved)
    try FileManager.default.createSymbolicLink(at: root, withDestinationURL: moved)
    do { try await WorktreeService.createOrRecover(plan); XCTFail("Replaced root accepted") }
    catch { XCTAssertTrue(error.localizedDescription.contains("根目录已改变")) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: plan.path))
  }

  @MainActor func testPersistedPendingCreationRecoversAsIndependentProject() async throws {
    let (base, source) = try await fixture()
    let data = base.appendingPathComponent("data")
    let snapshot = try await GitBranchService.snapshot(at: source)
    let plan = try await WorktreeService.plan(snapshot: snapshot, branch: nil, title: "Recovered", parent: base.appendingPathComponent("worktrees"))
    var library = WorkspaceLibrary()
    library.lastWorkspace = ""
    library.visit(source.path)
    library.permanentWorktrees = [plan]
    library.profiles[source.path] = BuildProfile(container: "App.xcodeproj", scheme: "App", configuration: "Release")
    try library.save(to: data.appendingPathComponent("workspace.json"))
    try await WorktreeService.createOrRecover(plan)
    let file = URL(fileURLWithPath: plan.path).appendingPathComponent("file")
    try write("unsaved development\n", file)
    let store = WorkspaceStore(dataRoot: data)
    await store.restore()
    let recovered = await store.recoverWorktree(plan.id)
    XCTAssertEqual(recovered?.ready, true, store.worktreeError ?? "")
    XCTAssertTrue(store.library.projects.contains(plan.path))
    XCTAssertEqual(store.library.projectTitle(plan.path), "Recovered")
    XCTAssertEqual(store.library.profiles[plan.path]?.scheme, "App")
    XCTAssertEqual(try String(contentsOf: file), "unsaved development\n")
    let saved = try WorkspaceLibrary.load(from: data.appendingPathComponent("workspace.json"))
    XCTAssertEqual(saved.permanentWorktrees.first?.ready, true)
    XCTAssertEqual(saved.projects.first, plan.path)
    await store.shutdown()
  }

  @MainActor func testSaveFailureDoesNotCreateUnrecordedWorktree() async throws {
    let (base, source) = try await fixture()
    let data = base.appendingPathComponent("data")
    let store = WorkspaceStore(dataRoot: data)
    await store.restore()
    store.library.visit(source.path)
    store.saveLibrary()
    let file = data.appendingPathComponent("workspace.json")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    let snapshot = try await GitBranchService.snapshot(at: source)
    let record = await store.createPermanentWorktree(snapshot: snapshot, branch: nil, title: "Failure")
    XCTAssertNil(record)
    XCTAssertNotNil(store.worktreeError)
    XCTAssertTrue(store.library.permanentWorktrees.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.worktreeRoot.path))
    XCTAssertFalse(store.busy)
    try FileManager.default.removeItem(at: file)
    await store.shutdown()
  }

  @MainActor func testRealAgentOpenRestoreMultipleTasksAndArchivePreserveWorktree() async throws {
    var repository = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    let executable = repository.appendingPathComponent("target/debug/shipios-agent")
    XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
    let (base, source) = try await fixture()
    let data = base.appendingPathComponent("data")
    let store = WorkspaceStore(dataRoot: data, agentExecutable: executable)
    await store.restore()
    store.library.visit(source.path)
    store.setWorktreeRoot(base.appendingPathComponent("custom-root"))
    store.beginWorktreeCreation(from: source.path)
    XCTAssertEqual(store.presentedOverlay, .worktreeCreation)
    let snapshot = try await GitBranchService.snapshot(at: source)
    let created = await store.createPermanentWorktree(snapshot: snapshot, branch: nil, title: "Long lived")
    let record = try XCTUnwrap(created, store.worktreeError ?? "")
    await store.openPermanentWorktree(record)
    XCTAssertTrue(store.connected, store.error ?? "")
    XCTAssertEqual(store.project?.path, record.path)
    XCTAssertEqual(store.workspace.root?.path, record.path)
    XCTAssertNil(store.presentedOverlay)
    store.notificationPreferences = .init(timing: .never)
    for id in ["first", "second"] {
      let run = AgentRun(id: id, kind: "chat", project: record.path, status: "succeeded",
        createdAt: 1, updatedAt: 1, request: .null, result: nil)
      store.library.chatRuns.append(run)
      store.library.attach(run, to: nil, note: id)
      store.runs.append(run)
    }
    store.selection = "first"
    store.draft = "persistent worktree draft"
    store.updateTask("second", archive: true)
    XCTAssertTrue(FileManager.default.fileExists(atPath: record.path))
    XCTAssertEqual(store.library.permanentWorktrees.count, 1)
    store.openSettings(.worktrees)
    store.closeSettings()
    XCTAssertEqual(store.draft, "persistent worktree draft")
    await store.shutdown()
    let restored = WorkspaceStore(dataRoot: data, agentExecutable: executable)
    await restored.restore()
    XCTAssertTrue(restored.connected, restored.error ?? "")
    XCTAssertEqual(restored.project?.path, record.path)
    XCTAssertEqual(restored.draft, "persistent worktree draft")
    XCTAssertEqual(restored.library.tasks.filter { $0.project == record.path }.count, 2)
    XCTAssertEqual(restored.library.tasks.first { $0.id == "second" }?.archived, true)
    let oldPath = record.path
    restored.setWorktreeRoot(nil)
    XCTAssertEqual(restored.library.permanentWorktrees.first?.path, oldPath)
    XCTAssertTrue(FileManager.default.fileExists(atPath: oldPath))
    await restored.shutdown()
  }

  func testLegacyLibraryDecodesWithDefaultWorktreeSettings() throws {
    let old = try JSONDecoder().decode(WorkspaceLibrary.self, from: Data("{}".utf8))
    XCTAssertNil(old.worktreeRoot)
    XCTAssertTrue(old.automaticallyDeleteManagedWorktrees)
    XCTAssertEqual(old.managedWorktreeLimit, 15)
    XCTAssertTrue(old.permanentWorktrees.isEmpty)
    XCTAssertTrue(old.managedWorktrees.isEmpty)
  }

  @MainActor func testManagedWorktreeLimitPrunesOldCheckoutAndRestoresActiveTaskOnSelection() async throws {
    let (base, source) = try await fixture()
    let data = base.appendingPathComponent("data")
    var repository = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    let agent = repository.appendingPathComponent("target/debug/shipios-agent")
    let store = WorkspaceStore(dataRoot: data, agentExecutable: agent)
    await store.restore()
    await store.open(source)
    XCTAssertTrue(store.connected, store.error ?? "")
    let snapshot = try await GitBranchService.snapshot(at: source)
    let oldID = UUID().uuidString
    let oldCreated = await store.createManagedWorktree(snapshot: snapshot,
      branch: nil, taskID: oldID)
    let old = try XCTUnwrap(oldCreated, store.worktreeError ?? "")
    let oldRoot = URL(fileURLWithPath: old.path)
    try write("staged\n", oldRoot.appendingPathComponent("file"))
    _ = try await git(["add", "file"], oldRoot)
    try write("unstaged\n", oldRoot.appendingPathComponent("file"))
    try write("untracked\n", oldRoot.appendingPathComponent("note"))
    var oldTask = WorkspaceTask(id: oldID, project: old.path,
      title: "Older worktree", runIDs: [])
    oldTask.updatedAt = Date(timeIntervalSince1970: 1_000_000_000)
    store.library.tasks.append(oldTask)
    XCTAssertTrue(store.saveLibrary())

    let newID = UUID().uuidString
    let newCreated = await store.createManagedWorktree(snapshot: snapshot,
      branch: nil, taskID: newID)
    let newer = try XCTUnwrap(newCreated, store.worktreeError ?? "")
    var newTask = WorkspaceTask(id: newID, project: newer.path,
      title: "Newer worktree", runIDs: [])
    newTask.updatedAt = Date(timeIntervalSince1970: 1_500_000_000)
    store.library.tasks.append(newTask)
    XCTAssertTrue(store.saveLibrary())
    XCTAssertEqual(store.managedWorktreeCount, 2)
    store.setManagedWorktreeLimit(1)
    await store.managedLimitCleanupTask?.value
    XCTAssertEqual(store.managedWorktreeCount, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: newer.path))
    XCTAssertEqual(store.library.managedWorktrees.first { $0.taskID == oldID }?.archivedPruned, true)
    XCTAssertFalse(store.library.tasks.first { $0.id == oldID }?.archived ?? true)
    let selected = await store.selectTaskAwaitingScope(oldTask)
    XCTAssertTrue(selected)
    await store.managedLimitCleanupTask?.value
    XCTAssertEqual(store.project?.path, old.path)
    XCTAssertEqual(try String(contentsOf: oldRoot.appendingPathComponent("file")), "unstaged\n")
    XCTAssertEqual(try String(contentsOf: oldRoot.appendingPathComponent("note")), "untracked\n")
    let status = try await git(["status", "--short"], oldRoot)
    XCTAssertTrue(status.contains("MM file"), status)
    XCTAssertTrue(status.contains("?? note"), status)
    XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: newer.path))
    XCTAssertEqual(store.managedWorktreeCount, 1)
    await store.shutdown()
  }

  @MainActor func testManagedWorktreeLimitCanBeDisabledAndSkipsPinnedTasks() async throws {
    let (base, source) = try await fixture()
    let data = base.appendingPathComponent("data")
    var store = WorkspaceStore(dataRoot: data)
    await store.restore()
    store.library.visit(source.path)
    XCTAssertTrue(store.saveLibrary())
    let snapshot = try await GitBranchService.snapshot(at: source)
    var paths: [String] = []
    for index in 0..<2 {
      let taskID = UUID().uuidString
      let created = await store.createManagedWorktree(snapshot: snapshot,
        branch: nil, taskID: taskID)
      let record = try XCTUnwrap(created, store.worktreeError ?? "")
      paths.append(record.path)
      var task = WorkspaceTask(id: taskID, project: record.path,
        title: "Pinned \(index)", runIDs: [])
      task.pinned = true
      store.library.tasks.append(task)
    }
    XCTAssertTrue(store.saveLibrary())
    store.setAutomaticManagedWorktreeDeletion(false)
    store.setManagedWorktreeLimit(250)
    XCTAssertEqual(store.library.managedWorktreeLimit, 250)
    store.setManagedWorktreeLimit(1)
    XCTAssertEqual(store.managedWorktreeCount, 2)
    await store.shutdown()
    store = WorkspaceStore(dataRoot: data)
    await store.restore()
    XCTAssertFalse(store.library.automaticallyDeleteManagedWorktrees)
    XCTAssertEqual(store.library.managedWorktreeLimit, 1)
    store.setAutomaticManagedWorktreeDeletion(true)
    await store.managedLimitCleanupTask?.value
    XCTAssertEqual(store.managedWorktreeCount, 2)
    XCTAssertTrue(paths.allSatisfy { FileManager.default.fileExists(atPath: $0) })
    await store.shutdown()
  }

  @MainActor func testManagedWorktreeReservesOneCheckoutWithoutBecomingPermanentProject() async throws {
    let (base, source) = try await fixture()
    let data = base.appendingPathComponent("data")
    let store = WorkspaceStore(dataRoot: data)
    await store.restore()
    store.library.visit(source.path)
    XCTAssertTrue(store.saveLibrary())
    let snapshot = try await GitBranchService.snapshot(at: source)
    let taskID = UUID().uuidString
    let result = await store.createManagedWorktree(snapshot: snapshot, branch: nil, taskID: taskID)
    let created = try XCTUnwrap(result, store.worktreeError ?? "")
    XCTAssertTrue(created.ready)
    XCTAssertEqual(created.taskID, taskID)
    XCTAssertTrue(FileManager.default.fileExists(atPath: created.path))
    XCTAssertTrue(store.library.permanentWorktrees.isEmpty)
    XCTAssertFalse(store.library.projects.contains(created.path))
    let checkout = try await GitBranchService.snapshot(at: URL(fileURLWithPath: created.path))
    XCTAssertNil(checkout.currentReference)
    XCTAssertEqual(checkout.currentCommit, snapshot.currentCommit)
    let repeated = await store.createManagedWorktree(snapshot: snapshot, branch: nil, taskID: taskID)
    XCTAssertEqual(repeated?.id, created.id)
    XCTAssertEqual(store.library.managedWorktrees.count, 1)
    await store.shutdown()
    let restored = WorkspaceStore(dataRoot: data)
    await restored.restore()
    XCTAssertEqual(restored.library.managedWorktrees.first, created)
    await restored.shutdown()
  }

  @MainActor func testLocalHandoffRejectsDirtyCheckoutWithoutMovingTaskOrCreatingWorktree() async throws {
    let (base, source) = try await fixture()
    let data = base.appendingPathComponent("data")
    let store = WorkspaceStore(dataRoot: data)
    await store.restore()
    let taskID = UUID().uuidString
    store.library.visit(source.path)
    store.library.tasks = [WorkspaceTask(id: taskID, project: source.path,
      title: "Local task", runIDs: [])]
    XCTAssertTrue(store.saveLibrary())
    try write("unfinished\n", source.appendingPathComponent("file"))

    let handedOff = await store.handOffTaskToWorktree(taskID)
    XCTAssertFalse(handedOff)
    XCTAssertTrue(store.worktreeError?.contains("未提交修改") == true)
    XCTAssertEqual(store.library.tasks.first?.project, source.path)
    XCTAssertTrue(store.library.managedWorktrees.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.worktreeRoot.path))
    XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("file")), "unfinished\n")
    await store.shutdown()
  }

  @MainActor func testWorktreeHandoffRejectsDirtyCheckoutAndDivergedCommits() async throws {
    let (base, source) = try await fixture()
    let store = WorkspaceStore(dataRoot: base.appendingPathComponent("data"))
    await store.restore()
    let taskID = UUID().uuidString
    store.library.visit(source.path)
    store.library.tasks = [WorkspaceTask(id: taskID, project: source.path,
      title: "Round trip", runIDs: [])]
    XCTAssertTrue(store.saveLibrary())
    let movedToWorktree = await store.handOffTaskToWorktree(taskID)
    XCTAssertTrue(movedToWorktree, store.worktreeError ?? "")
    let targetPath = try XCTUnwrap(store.library.managedWorktrees.first?.path)
    let target = URL(fileURLWithPath: targetPath)

    try write("unfinished\n", target.appendingPathComponent("file"))
    let rejectedDirty = await store.handOffTaskToLocal(taskID)
    XCTAssertFalse(rejectedDirty)
    XCTAssertEqual(store.library.tasks.first?.project, targetPath)
    let sourceAfterRejection = try await GitBranchService.snapshot(at: source)
    XCTAssertEqual(sourceAfterRejection.currentReference, "refs/heads/main")
    XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("file")), "unfinished\n")

    _ = try await git(["commit", "-qam", "Worktree commit"], target)
    let movedToLocal = await store.handOffTaskToLocal(taskID)
    XCTAssertTrue(movedToLocal, store.worktreeError ?? "")
    let branch = try XCTUnwrap(store.library.managedWorktrees.first?.handoffBranch)
    XCTAssertEqual(store.library.tasks.first?.project, source.path)
    try write("local diverged\n", source.appendingPathComponent("file"))
    _ = try await git(["commit", "-qam", "Local divergence"], source)
    try write("worktree diverged\n", target.appendingPathComponent("file"))
    _ = try await git(["commit", "-qam", "Worktree divergence"], target)
    let localBefore = try await GitBranchService.snapshot(at: source)
    let targetBefore = try await GitBranchService.snapshot(at: target)
    let rejectedDivergence = await store.handOffTaskToWorktree(taskID)
    XCTAssertFalse(rejectedDivergence)
    XCTAssertTrue(store.worktreeError?.contains("分叉") == true)
    XCTAssertEqual(store.library.tasks.first?.project, source.path)
    let localAfter = try await GitBranchService.snapshot(at: source)
    let targetAfter = try await GitBranchService.snapshot(at: target)
    XCTAssertEqual(localAfter.currentCommit, localBefore.currentCommit)
    XCTAssertEqual(localAfter.currentReference, "refs/heads/" + branch)
    XCTAssertEqual(targetAfter.currentCommit, targetBefore.currentCommit)
    XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("file")), "local diverged\n")
    XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("file")), "worktree diverged\n")
    await store.shutdown()
  }

  @MainActor func testManagedWorktreeRecoveryKeepsWorkAndOriginalCheckoutIdentity() async throws {
    let (base, source) = try await fixture()
    let data = base.appendingPathComponent("data")
    let snapshot = try await GitBranchService.snapshot(at: source)
    let checkout = try await WorktreeService.plan(snapshot: snapshot, branch: nil,
      title: "托管任务", parent: base.appendingPathComponent("worktrees"))
    let taskID = UUID().uuidString
    var library = WorkspaceLibrary()
    library.visit(source.path)
    library.managedWorktrees = [ManagedWorktree(taskID: taskID, checkout: checkout)]
    try library.save(to: data.appendingPathComponent("workspace.json"))
    try await WorktreeService.createOrRecover(checkout)
    let file = URL(fileURLWithPath: checkout.path).appendingPathComponent("file")
    try write("unfinished work\n", file)
    let store = WorkspaceStore(dataRoot: data)
    await store.restore()
    let result = await store.recoverManagedWorktree(taskID: taskID)
    let recovered = try XCTUnwrap(result, store.worktreeError ?? "")
    XCTAssertEqual(recovered.id, checkout.id)
    XCTAssertTrue(recovered.ready)
    XCTAssertEqual(try String(contentsOf: file), "unfinished work\n")
    XCTAssertEqual(store.library.managedWorktrees.count, 1)
    await store.shutdown()
  }

  @MainActor func testManagedWorktreeSaveFailureDoesNotCreateUnrecordedCheckout() async throws {
    let (base, source) = try await fixture()
    let data = base.appendingPathComponent("data")
    let store = WorkspaceStore(dataRoot: data)
    await store.restore()
    store.library.visit(source.path)
    XCTAssertTrue(store.saveLibrary())
    let recordFile = data.appendingPathComponent("workspace.json")
    try FileManager.default.removeItem(at: recordFile)
    try FileManager.default.createDirectory(at: recordFile, withIntermediateDirectories: true)
    let snapshot = try await GitBranchService.snapshot(at: source)
    let result = await store.createManagedWorktree(snapshot: snapshot, branch: nil,
      taskID: UUID().uuidString)
    XCTAssertNil(result)
    XCTAssertNotNil(store.worktreeError)
    XCTAssertTrue(store.library.managedWorktrees.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.worktreeRoot.path))
    try FileManager.default.removeItem(at: recordFile)
    await store.shutdown()
  }

  func testUnbornRepositoryCanUseCachedRemoteBranch() async throws {
    let (base, upstream) = try await fixture()
    let source = base.appendingPathComponent("unborn")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    _ = try await git(["init", "-q", "-b", "main"], source)
    _ = try await git(["remote", "add", "origin", upstream.path], source)
    _ = try await git(["fetch", "origin"], source)
    let snapshot = try await GitBranchService.snapshot(at: source)
    XCTAssertNil(snapshot.currentCommit)
    let remote = try XCTUnwrap(snapshot.branches.first { $0.name == "origin/main" })
    let plan = try await WorktreeService.plan(snapshot: snapshot, branch: remote,
      title: "Remote start", parent: base.appendingPathComponent("worktrees"))
    try await WorktreeService.createOrRecover(plan)
    let checkout = try await GitBranchService.snapshot(at: URL(fileURLWithPath: plan.path))
    XCTAssertEqual(checkout.currentCommit, remote.commit)
    XCTAssertNil(checkout.currentReference)
  }
}
