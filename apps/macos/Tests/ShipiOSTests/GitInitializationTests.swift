import XCTest
@testable import ShipiOS

@MainActor final class GitInitializationTests: XCTestCase {
  private func folder(_ name: String = "Project 中文 'quoted'") throws -> URL {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent("git-init-\(UUID())")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
    let root = GitBranchService.canonicalRoot(parent.appendingPathComponent(name))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return GitBranchService.canonicalRoot(root)
  }

  private func assertNoMetadata(_ root: URL, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path),
      file: file, line: line)
  }

  func testInitializeThenReviewStageUnstageAndFirstCommitWithoutLosingWorkspace() async throws {
    let root = try folder()
    try Data("new content\n".utf8).write(to: root.appendingPathComponent("new.txt"))
    let workspace = DeveloperWorkspace()
    workspace.root = root
    workspace.openFiles = ["new.txt"]
    workspace.selectedFile = "new.txt"
    workspace.fileText = "new content\n"
    workspace.commitMessage = "My first commit"
    workspace.reviewScope = .branch
    let created = await workspace.initializeGit(at: root)
    XCTAssertTrue(created)
    XCTAssertTrue(workspace.gitAvailable)
    XCTAssertTrue(workspace.canCommit)
    XCTAssertFalse(workspace.canInitializeGit)
    XCTAssertEqual(workspace.root, root)
    XCTAssertEqual(workspace.reviewScope, .unstaged)
    XCTAssertEqual(workspace.openFiles, ["new.txt"])
    XCTAssertEqual(workspace.selectedFile, "new.txt")
    XCTAssertEqual(workspace.fileText, "new content\n")
    XCTAssertEqual(workspace.commitMessage, "My first commit")
    XCTAssertEqual(workspace.files, ["new.txt"])
    XCTAssertEqual(workspace.visibleChanges.map(\.path), ["new.txt"])
    XCTAssertNil(workspace.error)
    let head = try await LocalWorkspaceService.git(["rev-parse", "--verify", "HEAD"], at: root)
    let index = try await GitReviewService.checked(["ls-files", "-z"], at: root)
    let remotes = try await GitReviewService.checked(["remote"], at: root)
    XCTAssertNotEqual(head.status, 0, "Initialization must not create a commit")
    XCTAssertTrue(index.isEmpty, "Initialization must not stage project files")
    XCTAssertTrue(remotes.isEmpty)
    await workspace.stage("new.txt", undo: false)
    await workspace.stage("new.txt", undo: true)
    let afterUnstage = try await GitReviewService.checked(["ls-files", "-z"], at: root)
    XCTAssertTrue(afterUnstage.isEmpty)
    await workspace.stage("new.txt", undo: false)
    _ = try await GitReviewService.checked(["config", "user.name", "Fixture"], at: root)
    _ = try await GitReviewService.checked(["config", "user.email", "fixture@example.invalid"], at: root)
    let committed = await workspace.commit()
    XCTAssertTrue(committed)
    let subject = try await GitReviewService.checked(["log", "-1", "--format=%s"], at: root)
    XCTAssertEqual(subject.trimmingCharacters(in: .newlines), "My first commit")
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("new.txt")), "new content\n")
  }

  func testReadOnlyAndBusyWorkspacesCannotInitializeAndCanRetryWhenWritable() async throws {
    let root = try folder()
    let workspace = DeveloperWorkspace()
    workspace.root = root
    var readOnly = true
    workspace.isGitReviewReadOnly = { readOnly }
    XCTAssertFalse(workspace.canInitializeGit)
    let denied = await workspace.initializeGit(at: root)
    XCTAssertFalse(denied)
    assertNoMetadata(root)
    readOnly = false
    for phase in 0..<3 {
      workspace.gitBusy = phase == 0
      workspace.gitRefreshing = phase == 1
      workspace.gitActionRunning = phase == 2
      let busy = await workspace.initializeGit(at: root)
      XCTAssertFalse(busy)
      assertNoMetadata(root)
    }
    workspace.gitActionRunning = false
    let allowed = await workspace.initializeGit(at: root)
    XCTAssertTrue(allowed)
  }

  func testPolicyChangeDuringPreflightLeavesRepositoryUninitializedAndShowsRetryableError() async throws {
    let root = try folder()
    let workspace = DeveloperWorkspace()
    workspace.root = root
    var checks = 0
    workspace.isGitReviewReadOnly = { checks += 1; return checks > 1 }
    let result = await workspace.initializeGit(at: root)
    XCTAssertFalse(result)
    XCTAssertTrue(workspace.error?.contains("只读") == true)
    XCTAssertFalse(workspace.gitBusy)
    assertNoMetadata(root)
    workspace.isGitReviewReadOnly = { false }
    let retried = await workspace.initializeGit(at: root)
    XCTAssertTrue(retried)
    XCTAssertNil(workspace.error)
  }

  func testQueuedActionForOldRootCannotInitializeCurrentProject() async throws {
    let source = try folder("Source"), target = try folder("Target")
    let workspace = DeveloperWorkspace()
    workspace.root = target
    workspace.commitMessage = "Keep target draft"
    let result = await workspace.initializeGit(at: source)
    XCTAssertFalse(result)
    assertNoMetadata(source)
    assertNoMetadata(target)
    XCTAssertEqual(workspace.root, target)
    XCTAssertEqual(workspace.commitMessage, "Keep target draft")
    workspace.root = nil
    XCTAssertFalse(workspace.canInitializeGit)
    let projectless = await workspace.initializeGit(at: target)
    XCTAssertFalse(projectless)
  }

  func testAuthorizationCancellationAndProjectGenerationChangePreventInitialization() async throws {
    let root = try folder()
    let workspace = DeveloperWorkspace()
    workspace.root = root
    let check = workspace.gitMutationAuthorization(at: root)
    do {
      try await GitInitializationService.initialize(at: root, authorize: {
        workspace.setProject(nil)
        workspace.root = root
        try check()
      })
      XCTFail("Old project generation must be rejected")
    } catch { XCTAssertTrue(error is CancellationError) }
    assertNoMetadata(root)
    do {
      try await GitInitializationService.initialize(at: root, authorize: { throw CancellationError() })
      XCTFail("Cancelled initialization must not write")
    } catch { XCTAssertTrue(error is CancellationError) }
    assertNoMetadata(root)
  }

  func testExistingAncestorRepositoryIsNotReinitializedOrNested() async throws {
    let parent = try folder("Existing repository")
    _ = try await GitReviewService.checked(["init", "-q"], at: parent)
    let child = parent.appendingPathComponent("Nested project")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    let originalConfig = try Data(contentsOf: parent.appendingPathComponent(".git/config"))
    let workspace = DeveloperWorkspace()
    workspace.root = child
    await workspace.refreshGit()
    XCTAssertTrue(workspace.gitAvailable)
    let result = await workspace.initializeGit(at: child)
    XCTAssertFalse(result)
    XCTAssertNil(workspace.error)
    assertNoMetadata(child)
    XCTAssertEqual(try Data(contentsOf: parent.appendingPathComponent(".git/config")), originalConfig)
    XCTAssertEqual(workspace.root, child)
  }

  func testExistingInvalidAndDanglingGitMetadataAreKeptUntouched() async throws {
    for dangling in [false, true] {
      let root = try folder()
      let metadata = root.appendingPathComponent(".git")
      if dangling {
        try FileManager.default.createSymbolicLink(atPath: metadata.path, withDestinationPath: "missing-git")
      } else {
        try Data("invalid gitdir: keep this\n".utf8).write(to: metadata)
      }
      do {
        try await GitInitializationService.initialize(at: root)
        XCTFail("Existing metadata must not be replaced")
      } catch { XCTAssertTrue(error.localizedDescription.contains("已有 Git 元数据")) }
      if dangling {
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: metadata.path), "missing-git")
      } else {
        XCTAssertEqual(try String(contentsOf: metadata), "invalid gitdir: keep this\n")
      }
    }
  }

  func testExistingRepositoryAndBareRepositoryAreNotReinitialized() async throws {
    for bare in [false, true] {
      let root = try folder()
      _ = try await GitReviewService.checked(bare ? ["init", "-q", "--bare"] : ["init", "-q"], at: root)
      let config = root.appendingPathComponent(bare ? "config" : ".git/config")
      let previous = try Data(contentsOf: config)
      do {
        try await GitInitializationService.initialize(at: root)
        XCTFail("Existing repository must not be reinitialized")
      } catch { XCTAssertTrue(error.localizedDescription.contains(bare ? "裸 Git 仓库" : "已有 Git 元数据")) }
      XCTAssertEqual(try Data(contentsOf: config), previous)
      if bare { assertNoMetadata(root) }
    }
  }

  func testDirectoryReplacementAndRetargetedAliasAfterPreflightAreRejected() async throws {
    for alias in [false, true] {
      let root = try folder("Source"), other = try folder("Other")
      let input = alias ? root.deletingLastPathComponent().appendingPathComponent("Alias") : root
      if alias { try FileManager.default.createSymbolicLink(at: input, withDestinationURL: root) }
      do {
        try await GitInitializationService.initialize(at: input, authorize: {
          if alias {
            try FileManager.default.removeItem(at: input)
            try FileManager.default.createSymbolicLink(at: input, withDestinationURL: other)
          } else {
            try FileManager.default.moveItem(at: root, to: root.appendingPathExtension("old"))
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
          }
        })
        XCTFail("Replaced or redirected directory must not be initialized")
      } catch { XCTAssertTrue(error.localizedDescription.contains("项目目录已变化")) }
      assertNoMetadata(root)
      assertNoMetadata(other)
    }
  }

  func testMetadataAppearingDuringPreflightIsPreservedAndInvalidDirectoryCanBeRetried() async throws {
    let root = try folder()
    do {
      try await GitInitializationService.initialize(at: root, authorize: {
        try Data("externally created".utf8).write(to: root.appendingPathComponent(".git"))
      })
      XCTFail("Concurrent metadata must not be overwritten")
    } catch { XCTAssertTrue(error.localizedDescription.contains("已有 Git 元数据")) }
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(".git")), "externally created")
    let missing = root.appendingPathComponent("Missing")
    let workspace = DeveloperWorkspace()
    workspace.root = missing
    let invalid = await workspace.initializeGit(at: missing)
    XCTAssertFalse(invalid)
    XCTAssertNotNil(workspace.error)
    XCTAssertFalse(workspace.gitBusy)
    try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
    // A broken parent repository remains a boundary too.
    try FileManager.default.removeItem(at: root.appendingPathComponent(".git"))
    // The unavailable page now offers Retry; creation returns only after a
    // successful directory/repository check, without clearing errors manually.
    XCTAssertFalse(workspace.canInitializeGit)
    await workspace.refreshGit()
    XCTAssertTrue(workspace.canInitializeGit)
    let retried = await workspace.initializeGit(at: missing)
    XCTAssertTrue(retried)
    XCTAssertNil(workspace.error)
  }

  func testSettingsAndTaskOwnedReviewInitializeTheirOwnProjectAndKeepMainDraft() async throws {
    let main = try folder("Main"), taskRoot = try folder("Task")
    let store = WorkspaceStore(dataRoot: main.deletingLastPathComponent().appendingPathComponent("Data"))
    store.libraryLoaded = true
    store.scopeLoaded = true
    store.connected = true
    store.project = main
    store.workspace.root = main
    store.draft = "Keep main draft"
    store.openSettings(.codeReview)
    store.openReviewFromSettings()
    XCTAssertEqual(store.destination, .workspace)
    XCTAssertNotNil(store.activeWorkspaceContentTab)
    XCTAssertEqual(store.draft, "Keep main draft")
    let owner = WorkspaceTask(id: "task-owner", project: taskRoot.path, title: "Task", runIDs: [])
    store.library.tasks = [owner]
    let resources = TaskWindowResources()
    resources.prepare(owner.id, store: store)
    defer { resources.shutdown() }
    let workspace = try XCTUnwrap(resources.panels.tasks[owner.id]?.workspace)
    await Task.yield()
    await workspace.refreshFiles()
    await workspace.refreshGit()
    for _ in 0..<100 where workspace.gitRefreshing { try await Task.sleep(nanoseconds: 10_000_000) }
    store.library.gitPreferences.readOnlyReview = true
    let denied = await workspace.initializeGit(at: taskRoot)
    XCTAssertFalse(denied)
    assertNoMetadata(taskRoot)
    store.library.gitPreferences.readOnlyReview = false
    let created = await workspace.initializeGit(at: taskRoot)
    XCTAssertTrue(created)
    assertNoMetadata(main)
    XCTAssertEqual(store.project, main)
    XCTAssertEqual(store.workspace.root, main)
    XCTAssertEqual(store.draft, "Keep main draft")
    let detached = DetachedReviewSession()
    detached.configure(store: store, owner: owner.id)
    await Task.yield()
    await detached.workspace.refreshFiles()
    await detached.workspace.refreshGit()
    for _ in 0..<500 where detached.workspace.gitRefreshing { try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertTrue(detached.workspace.gitAvailable)
    XCTAssertEqual(detached.workspace.root, taskRoot)
    detached.shutdown()
  }

  func testDetachedReviewCanCreateRepositoryWithoutRetargetingMainWorkspace() async throws {
    let main = try folder("Main"), source = try folder("Detached source")
    let store = WorkspaceStore(dataRoot: main.deletingLastPathComponent().appendingPathComponent("Data"))
    store.libraryLoaded = true
    store.scopeLoaded = true
    store.project = main
    store.workspace.root = main
    store.draft = "Keep main draft"
    let owner = WorkspaceTask(id: "detached-owner", project: source.path, title: "Source", runIDs: [])
    store.library.tasks = [owner]
    let detached = DetachedReviewSession()
    detached.configure(store: store, owner: owner.id)
    defer { detached.shutdown() }
    await Task.yield()
    await detached.workspace.refreshFiles()
    await detached.workspace.refreshGit()
    for _ in 0..<100 where detached.workspace.gitRefreshing { try await Task.sleep(nanoseconds: 10_000_000) }
    store.library.gitPreferences.readOnlyReview = true
    let denied = await detached.workspace.initializeGit(at: source)
    XCTAssertFalse(denied)
    assertNoMetadata(source)
    store.library.gitPreferences.readOnlyReview = false
    let created = await detached.workspace.initializeGit(at: source)
    XCTAssertTrue(created)
    XCTAssertEqual(detached.owner, owner.id)
    XCTAssertEqual(detached.workspace.root, source)
    XCTAssertEqual(store.workspace.root, main)
    XCTAssertEqual(store.project, main)
    XCTAssertEqual(store.draft, "Keep main draft")
    assertNoMetadata(main)
  }
}
