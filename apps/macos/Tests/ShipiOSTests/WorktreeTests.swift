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
    XCTAssertTrue(old.permanentWorktrees.isEmpty)
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
