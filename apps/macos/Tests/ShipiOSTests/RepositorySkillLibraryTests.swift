import XCTest
@testable import ShipiOS

final class RepositorySkillLibraryTests: XCTestCase {
  private func project(_ path: URL, instructions: String = "Instructions") throws -> URL {
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    try PluginStorage.createRepositorySkill(id: "review", description: "Review this project",
      instructions: instructions, project: path)
    return path
  }

  func testLibraryIncludesSavedProjectsAndDeduplicatesSharedFilesInPreferredScope() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = try project(root.appendingPathComponent("Repo"))
    try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
    let first = try project(repo.appendingPathComponent("First"))
    let second = try project(repo.appendingPathComponent("Second"))
    let other = try project(root.appendingPathComponent("Other"))
    let library = PluginStorage.repositorySkillLibrary(projectPaths: [second.path, first.path, other.path, second.path])
    XCTAssertEqual(library.skills.count, 4)
    XCTAssertEqual(Set(library.skills.map(\.id)).count, 4)
    XCTAssertTrue(library.issues.isEmpty)
    let shared = try XCTUnwrap(library.skills.first { $0.repositoryRoot?.path == repo.path })
    XCTAssertEqual(library.projectPathsBySkillID[shared.id], second.path)
    XCTAssertEqual(library.projectPathsBySkillID[library.skills.first { $0.repositoryRoot?.path == first.path }!.id], first.path)
  }

  func testDamagedProjectDoesNotHideHealthyProjectsAndNonLocalPathsAreIgnored() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let good = try project(root.appendingPathComponent("Good"))
    let bad = try project(root.appendingPathComponent("Bad"))
    let metadata = bad.appendingPathComponent(".agents/skills/review/agents/openai.yaml")
    try FileManager.default.createDirectory(at: metadata.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("interface: [unterminated".utf8).write(to: metadata)
    let file = root.appendingPathComponent("RegularFile")
    try Data("not a project".utf8).write(to: file)
    let library = PluginStorage.repositorySkillLibrary(projectPaths: [bad.path, good.path, file.path, bad.path, "ssh://example/repo", "relative"])
    XCTAssertEqual(library.skills.map { $0.repositoryRoot?.path }, [good.path])
    XCTAssertEqual(Set(library.issues.map(\.projectPath)), [bad.path, file.path])
  }

  @MainActor func testKnownScopesIncludeTaskProjectsAndCurrentScopeWithoutDuplicates() {
    let store = WorkspaceStore()
    store.project = URL(fileURLWithPath: "/Current")
    store.library.projects = ["/Saved", "/Current", "", "ssh://remote/repo"]
    store.library.tasks = [.init(id: "saved-task", project: "/TaskProject", title: "Task", runIDs: [], createdAt: Date(), updatedAt: Date())]
    XCTAssertEqual(store.skillLibraryProjectPaths, ["/Current", "/Saved", "/TaskProject"])
  }

  @MainActor func testLibraryCreatesEditsAndTogglesKnownOtherProjectWithoutSwitchingWorkspace() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let current = root.appendingPathComponent("Current"), target = root.appendingPathComponent("Target")
    let unknown = root.appendingPathComponent("Unknown")
    for path in [current, target, unknown] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"))
    store.project = current
    store.library.projects = [current.path, target.path]
    store.draft = "keep current draft"
    await store.loadPlugins()
    XCTAssertTrue(store.createRepositorySkill(id: "review", description: "Review", instructions: "Original", projectPath: target.path))
    let skill = try XCTUnwrap(PluginStorage.repositorySkills(project: target).first)
    let original = try String(contentsOf: skill.fileURL)
    XCTAssertTrue(store.updateRepositorySkill(id: skill.id, text: "# Updated\nUpdated instructions",
      expectedOriginal: original, project: target, contextProjectPath: target.path))
    XCTAssertTrue(store.setSkillEnabled(false, skill: skill, projectPath: target.path))
    XCTAssertFalse(store.isSkillEnabled(skill))
    XCTAssertTrue(store.composerSkills(for: target.path).isEmpty)
    XCTAssertEqual(store.currentProjectKey, current.path)
    XCTAssertEqual(store.draft, "keep current draft")
    XCTAssertFalse(store.createRepositorySkill(id: "review", description: "Review", instructions: "No", projectPath: unknown.path))
    XCTAssertFalse(store.updateRepositorySkill(id: skill.id, text: "Wrong", expectedOriginal: "# Updated\nUpdated instructions",
      project: target, contextProjectPath: unknown.path))
    store.library.projects = [current.path]
    XCTAssertFalse(store.setSkillEnabled(true, skill: skill, projectPath: target.path))
    XCTAssertTrue(try String(contentsOf: skill.fileURL).contains("Updated instructions"))
  }

  @MainActor func testCrossProjectTrialPreservesOriginalTaskDraftAndAttachmentsAndReturnsToIt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try project(root.appendingPathComponent("First"))
    let second = try project(root.appendingPathComponent("Second"))
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"),
      agentExecutable: repository.appendingPathComponent("target/debug/shipios-agent"))
    await store.restore()
    await store.open(first)
    XCTAssertTrue(store.connected, store.error ?? "No connection")
    store.library.visit(second.path)
    let previous = WorkspaceTask(id: "previous", project: first.path, title: "Previous", runIDs: [], createdAt: Date(), updatedAt: Date())
    store.library.tasks.append(previous)
    store.selectTask(previous)
    store.draft = "keep previous task"
    let attachment = FileAttachment(id: UUID(), name: "notes.txt", byteCount: 12, sha256: "fixture", isPDF: false)
    store.library.draftFiles[previous.id] = [attachment]
    store.skillLibraryQuery = "review"
    try store.commitLibrary(store.library)
    await store.loadPlugins()
    store.showSkills()
    let skill = try XCTUnwrap(PluginStorage.repositorySkills(project: second).first)
    XCTAssertTrue(store.canTrySkill(skill.id, projectPath: second.path))
    let tried = await store.trySkill(skill.id, projectPath: second.path)
    XCTAssertTrue(tried, store.pluginsError ?? "No trial")
    XCTAssertEqual(store.selectedTask?.project, second.path)
    XCTAssertEqual(store.draft, skill.trialPrompt)
    XCTAssertTrue(store.selectedTask?.runIDs.isEmpty == true)
    XCTAssertEqual(store.library.drafts[previous.id], "keep previous task")
    XCTAssertEqual(store.library.draftFiles[previous.id], [attachment])
    XCTAssertEqual(store.skillLibraryQuery, "review")
    XCTAssertFalse(store.skillTrialInProgress)
    let persisted = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    XCTAssertEqual(persisted.drafts[previous.id], "keep previous task")
    let returned = await store.selectTaskAwaitingScope(previous)
    XCTAssertTrue(returned)
    XCTAssertEqual(store.draft, "keep previous task")
    XCTAssertEqual(store.draftFiles, [attachment])
    let alias = root.appendingPathComponent("Alias", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: second)
    store.library.visit(alias.path)
    let aliasSkill = try XCTUnwrap(PluginStorage.repositorySkills(project: alias).first)
    let aliasedTrial = await store.trySkill(aliasSkill.id, projectPath: alias.path)
    XCTAssertTrue(aliasedTrial, store.pluginsError ?? "Alias trial failed")
    XCTAssertEqual(store.selectedTask?.project, second.resolvingSymlinksInPath().standardizedFileURL.path)
    XCTAssertEqual(store.library.drafts[previous.id], "keep previous task")
    await store.shutdown()
  }

  @MainActor func testStaleCrossProjectTrialFailsBeforeChangingScopeOrCreatingTask() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try project(root.appendingPathComponent("First")), second = try project(root.appendingPathComponent("Second"))
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"))
    store.project = first
    store.libraryLoaded = true; store.restoringLibrary = false; store.scopeLoaded = true
    store.library.projects = [first.path, second.path]
    await store.loadPlugins()
    let skill = try XCTUnwrap(store.composerSkills(for: second.path).first)
    try FileManager.default.removeItem(at: skill.fileURL)
    let tried = await store.trySkill(skill.id, projectPath: second.path)
    XCTAssertFalse(tried)
    XCTAssertEqual(store.currentProjectKey, first.path)
    XCTAssertTrue(store.library.tasks.isEmpty)
    XCTAssertFalse(store.skillTrialInProgress)
    XCTAssertFalse(store.canTrySkill(skill.id, projectPath: "/Unknown"))
  }

  @MainActor func testFailedProjectConnectionRestoresSourcePageAndDoesNotCreateTask() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try project(root.appendingPathComponent("First")), second = try project(root.appendingPathComponent("Second"))
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"),
      agentExecutable: root.appendingPathComponent("missing-agent"))
    store.project = first
    store.libraryLoaded = true; store.restoringLibrary = false; store.scopeLoaded = true
    store.library.projects = [first.path, second.path]
    store.draft = "keep source draft"
    store.skillLibraryQuery = "review"
    await store.loadPlugins()
    store.showSkills()
    let skill = try XCTUnwrap(store.composerSkills(for: second.path).first)
    let tried = await store.trySkill(skill.id, projectPath: second.path)
    XCTAssertFalse(tried)
    XCTAssertEqual(store.currentProjectKey, first.path)
    XCTAssertEqual(store.destination, .skills)
    XCTAssertEqual(store.draft, "keep source draft")
    XCTAssertEqual(store.skillLibraryQuery, "review")
    XCTAssertTrue(store.library.tasks.isEmpty)
    XCTAssertFalse(store.skillTrialInProgress)
    XCTAssertNotNil(store.pluginsError)
    await store.shutdown()
  }

}
