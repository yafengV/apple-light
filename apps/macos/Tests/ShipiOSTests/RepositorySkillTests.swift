import XCTest
@testable import ShipiOS

final class RepositorySkillTests: XCTestCase {
  private func project(at base: URL, name: String, text: String) throws -> URL {
    let root = base.appendingPathComponent(name, isDirectory: true)
    let skill = root.appendingPathComponent(".agents/skills/review/SKILL.md")
    try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try Data(text.utf8).write(to: skill)
    return root
  }

  func testRepositorySkillsAreScopedAndUsableOnlyInOwningProject() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let first = try project(at: base, name: "First",
      text: "---\nname: first-review\ndescription: Review First only\n---\n\nFIRST-INSTRUCTIONS")
    let second = try project(at: base, name: "Second",
      text: "---\nname: second-review\ndescription: Review Second only\n---\n\nSECOND-INSTRUCTIONS")
    let root = base.appendingPathComponent("ShipiOS")
    let preferences = try PluginStorage.load(root: root)
    let firstSkill = try XCTUnwrap(PluginStorage.repositorySkills(project: first).first)
    XCTAssertEqual(firstSkill.id, "repo:\(first.path)/review")
    XCTAssertEqual(firstSkill.mention, "repo/review")
    XCTAssertEqual(firstSkill.title, "first-review")
    XCTAssertEqual(firstSkill.summary, "Review First only")
    XCTAssertEqual(try PluginStorage.readSkill(id: firstSkill.id, root: root, repositoryRoot: first),
      try String(contentsOf: firstSkill.fileURL))
    XCTAssertThrowsError(try PluginStorage.readSkill(id: firstSkill.id, root: root))

    let firstContext = try PluginStorage.promptContext(prompt: "$repo/review", preferences: preferences,
      root: root, repositoryRoot: first)
    XCTAssertTrue(firstContext.instructions.contains("FIRST-INSTRUCTIONS"))
    XCTAssertFalse(firstContext.instructions.contains("SECOND-INSTRUCTIONS"))
    XCTAssertTrue(firstContext.ids.isEmpty)
    XCTAssertEqual(firstContext.skillIDs, [firstSkill.id])
    let secondContext = try PluginStorage.promptContext(prompt: "$repo/review", preferences: preferences,
      root: root, repositoryRoot: second)
    XCTAssertTrue(secondContext.instructions.contains("SECOND-INSTRUCTIONS"))
    XCTAssertFalse(secondContext.instructions.contains("FIRST-INSTRUCTIONS"))
    XCTAssertTrue(try PluginStorage.promptContext(prompt: "$repo/review", preferences: preferences,
      root: root).instructions.isEmpty)
    XCTAssertTrue(try PluginStorage.promptContext(prompt: firstSkill.promptReference,
      preferences: preferences, root: root, repositoryRoot: first)
      .instructions.contains("FIRST-INSTRUCTIONS"))
  }

  func testRepositorySkillDiscoveryRejectsSymlinkedSource() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let external = try project(at: base, name: "External", text: "# External\n")
    let root = base.appendingPathComponent("Project")
    try FileManager.default.createDirectory(at: root.appendingPathComponent(".agents"),
      withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent(".agents/skills"),
      withDestinationURL: external.appendingPathComponent(".agents/skills"))
    XCTAssertThrowsError(try PluginStorage.repositorySkills(project: root))
  }

  func testCreateAndEditRepositorySkillStayInProjectAndRejectStaleWrites() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let project = base.appendingPathComponent("Project")
    let other = base.appendingPathComponent("Other")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try PluginStorage.createRepositorySkill(id: "review", description: "Review changes",
      instructions: "Check correctness.", project: project)
    let skill = try XCTUnwrap(PluginStorage.repositorySkills(project: project).first)
    XCTAssertEqual(skill.summary, "Review changes")
    XCTAssertTrue(try PluginStorage.repositorySkills(project: other).isEmpty)
    let original = try String(contentsOf: skill.fileURL)
    XCTAssertTrue(original.contains("Check correctness."))
    XCTAssertThrowsError(try PluginStorage.createRepositorySkill(id: "Review", description: "Duplicate",
      instructions: "Replace", project: project))
    XCTAssertThrowsError(try PluginStorage.createRepositorySkill(id: "bad/name", description: "Bad",
      instructions: "No", project: project))
    let resource = skill.fileURL.deletingLastPathComponent().appendingPathComponent("notes.txt")
    try Data("keep".utf8).write(to: resource)
    try PluginStorage.updateRepositorySkill(id: skill.id, text: "# Edited\nNew instructions.",
      expectedOriginal: original, project: project)
    XCTAssertEqual(try String(contentsOf: resource), "keep")
    XCTAssertEqual(try PluginStorage.repositorySkills(project: project).first?.title, "Edited")
    XCTAssertThrowsError(try PluginStorage.updateRepositorySkill(id: skill.id, text: "stale",
      expectedOriginal: original, project: project))
    XCTAssertEqual(try String(contentsOf: skill.fileURL), "# Edited\nNew instructions.")
  }

  func testRepositorySkillCreationRejectsLinkedDirectory() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let project = base.appendingPathComponent("Project")
    let outside = base.appendingPathComponent("Outside")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: project.appendingPathComponent(".agents"), withDestinationURL: outside)
    XCTAssertThrowsError(try PluginStorage.createRepositorySkill(id: "review", description: "Review",
      instructions: "Inspect.", project: project))
    XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("skills").path))
  }

  func testSameNamedPersonalAndRepositorySkillsRequireExactReference() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let project = try project(at: base, name: "Project", text: "# Repo Review\nREPO-INSTRUCTIONS")
    let root = base.appendingPathComponent("Data")
    let preferences = try PluginStorage.createStandaloneSkill(
      id: "review", description: "Private review", instructions: "PRIVATE-INSTRUCTIONS", root: root)
    let repository = try XCTUnwrap(PluginStorage.repositorySkills(project: project).first)
    let personal = try XCTUnwrap(PluginStorage.skills(preferences: preferences, root: root).first)
    XCTAssertNotEqual(repository.id, personal.id)
    XCTAssertTrue(try PluginStorage.promptContext(prompt: "$review", preferences: preferences,
      root: root, repositoryRoot: project).instructions.isEmpty)
    XCTAssertTrue(try PluginStorage.promptContext(prompt: repository.promptReference,
      preferences: preferences, root: root, repositoryRoot: project)
      .instructions.contains("REPO-INSTRUCTIONS"))
    XCTAssertFalse(try PluginStorage.promptContext(prompt: repository.promptReference,
      preferences: preferences, root: root, repositoryRoot: project)
      .instructions.contains("PRIVATE-INSTRUCTIONS"))
    XCTAssertTrue(try PluginStorage.promptContext(prompt: personal.promptReference,
      preferences: preferences, root: root, repositoryRoot: project)
      .instructions.contains("PRIVATE-INSTRUCTIONS"))
  }

  func testNestedGitProjectFindsEachApplicableScopeAndKeepsNamesDistinct() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let root = try project(at: base, name: "Repository", text: "# Shared\nROOT-INSTRUCTIONS")
    try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"),
      withIntermediateDirectories: true)
    let app = try project(at: root, name: "App", text: "# Local\nAPP-INSTRUCTIONS")
    let nested = app.appendingPathComponent("Sources", isDirectory: true)
    let sibling = root.appendingPathComponent("Other", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
    let skills = try PluginStorage.repositorySkills(project: nested)
    XCTAssertEqual(skills.count, 2)
    XCTAssertEqual(skills.map(\.repositoryRoot), [app, root])
    XCTAssertEqual(Set(skills.map(\.id)).count, 2)
    XCTAssertEqual(try PluginStorage.repositorySkills(project: sibling).map(\.repositoryRoot), [root])
    let privateRoot = base.appendingPathComponent("Data")
    let preferences = try PluginStorage.load(root: privateRoot)
    XCTAssertTrue(try PluginStorage.promptContext(prompt: "$repo/review", preferences: preferences,
      root: privateRoot, repositoryRoot: nested).instructions.isEmpty)
    let context = try PluginStorage.promptContext(
      prompt: skills.map(\.promptReference).joined(separator: " "), preferences: preferences,
      root: privateRoot, repositoryRoot: nested)
    XCTAssertTrue(context.instructions.contains("ROOT-INSTRUCTIONS"))
    XCTAssertTrue(context.instructions.contains("APP-INSTRUCTIONS"))
    XCTAssertEqual(context.skillIDs, skills.map(\.id))
    XCTAssertEqual(try PluginStorage.readSkill(id: skills[0].id, root: privateRoot,
      repositoryRoot: nested), try String(contentsOf: skills[0].fileURL))
  }

  func testUnrelatedParentWithoutGitDoesNotLeakSkills() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let parent = try project(at: base, name: "Parent", text: "# Parent\n")
    let child = parent.appendingPathComponent("Child", isDirectory: true)
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    XCTAssertTrue(try PluginStorage.repositorySkills(project: child).isEmpty)
  }

  @MainActor func testComposerAndTrialUseProjectScopeAndReloadChanges() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let first = try project(at: base, name: "First", text: "# First Review\nFIRST-INSTRUCTIONS")
    let second = try project(at: base, name: "Second", text: "# Second Review\nSECOND-INSTRUCTIONS")
    let store = WorkspaceStore(dataRoot: base.appendingPathComponent("Data"))
    store.libraryLoaded = true
    store.restoringLibrary = false
    store.scopeLoaded = true
    await store.loadPlugins()
    store.project = first
    XCTAssertEqual(store.composerSkills.map(\.id), ["repo:\(first.path)/review"])
    XCTAssertEqual(store.composerSkills(for: second.path).first?.title, "Second Review")
    XCTAssertTrue(store.trySkill("repo:\(first.path)/review"))
    XCTAssertEqual(store.selectedTask?.project, first.path)
    XCTAssertTrue(store.draft.contains("[$review]"))
    let file = first.appendingPathComponent(".agents/skills/review/SKILL.md")
    try Data("# Updated Review\nUPDATED-INSTRUCTIONS".utf8).write(to: file)
    XCTAssertEqual(store.composerSkills(for: first.path).first?.title, "First Review")
    await store.loadPlugins()
    XCTAssertEqual(store.composerSkills(for: first.path).first?.title, "Updated Review")
    store.pluginsEnabled = false
    XCTAssertTrue(store.composerSkills(for: first.path).isEmpty)
  }

  @MainActor func testStoreCreatesEditsAndRefreshesRepositorySkillsWithoutTouchingPrivateScope() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let project = base.appendingPathComponent("Project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let store = WorkspaceStore(dataRoot: base.appendingPathComponent("Data"))
    store.project = project
    store.draft = "existing draft"
    await store.loadPlugins()
    XCTAssertTrue(store.createRepositorySkill(id: "review", description: "Review code",
      instructions: "Check changes.", projectPath: project.path))
    XCTAssertEqual(store.composerSkills.map(\.id), ["repo:\(project.path)/review"])
    XCTAssertTrue(store.installedPluginSkills.isEmpty)
    let skill = try XCTUnwrap(store.repositorySkills(for: project.path).first)
    let original = try PluginStorage.readSkill(id: skill.id, root: store.dataRoot, repositoryRoot: project)
    XCTAssertTrue(store.updateRepositorySkill(id: skill.id, text: "# Updated\nNew instructions.",
      expectedOriginal: original, project: project))
    XCTAssertEqual(store.composerSkills.first?.title, "Updated")
    XCTAssertEqual(store.draft, "existing draft")
    store.project = nil
    XCTAssertFalse(store.updateRepositorySkill(id: skill.id, text: "wrong project",
      expectedOriginal: "# Updated\nNew instructions.", project: project))
    XCTAssertTrue(store.composerSkills.isEmpty)
  }

  @MainActor func testNestedProjectCanEditAncestorSkillButOtherProjectCannot() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let root = try project(at: base, name: "Repository", text: "# Shared\nOLD")
    try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"),
      withIntermediateDirectories: true)
    let child = root.appendingPathComponent("App", isDirectory: true)
    let other = base.appendingPathComponent("Other", isDirectory: true)
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    let store = WorkspaceStore(dataRoot: base.appendingPathComponent("Data"))
    store.project = child
    await store.loadPlugins()
    let skill = try XCTUnwrap(store.repositorySkills(for: child.path).first)
    let original = try String(contentsOf: skill.fileURL)
    XCTAssertTrue(store.updateRepositorySkill(id: skill.id, text: "# Shared\nNEW",
      expectedOriginal: original, project: root))
    XCTAssertTrue(try String(contentsOf: skill.fileURL).contains("NEW"))
    store.project = other
    XCTAssertFalse(store.updateRepositorySkill(id: skill.id, text: "wrong project",
      expectedOriginal: "# Shared\nNEW", project: root))
  }

  func testDisableRepositorySkillPersistsBySourceAndLeavesFilesAndOtherProjectsUnchanged() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let first = try project(at: base, name: "First", text: "# First\nFIRST-INSTRUCTIONS")
    let second = try project(at: base, name: "Second", text: "# Second\nSECOND-INSTRUCTIONS")
    let root = base.appendingPathComponent("Data")
    let skill = try XCTUnwrap(PluginStorage.repositorySkills(project: first).first)
    let other = try XCTUnwrap(PluginStorage.repositorySkills(project: second).first)
    let original = try Data(contentsOf: skill.fileURL)
    _ = try PluginStorage.setRepositorySkillEnabled(false, id: skill.id, project: first, root: root)
    let loaded = try PluginStorage.load(root: root)
    XCTAssertFalse(loaded.isSkillEnabled(skill))
    XCTAssertTrue(loaded.isSkillEnabled(other))
    XCTAssertEqual(try Data(contentsOf: skill.fileURL), original)
    XCTAssertEqual(try PluginStorage.repositorySkills(project: first).map(\.id), [skill.id])
    for prompt in [skill.promptReference, "$repo/review", "$review"] {
      XCTAssertTrue(try PluginStorage.promptContext(prompt: prompt, preferences: loaded,
        root: root, repositoryRoot: first).instructions.isEmpty)
    }
    XCTAssertTrue(try PluginStorage.promptContext(prompt: other.promptReference, preferences: loaded,
      root: root, repositoryRoot: second).instructions.contains("SECOND-INSTRUCTIONS"))
    XCTAssertThrowsError(try PluginStorage.setRepositorySkillEnabled(true, id: skill.id,
      project: second, root: root))
    let enabled = try PluginStorage.setRepositorySkillEnabled(true, id: skill.id, project: first, root: root)
    XCTAssertTrue(enabled.isSkillEnabled(skill))
    XCTAssertTrue(try PluginStorage.promptContext(prompt: skill.promptReference, preferences: enabled,
      root: root, repositoryRoot: first).instructions.contains("FIRST-INSTRUCTIONS"))
  }

  func testSharedRepositoryToggleUsesCanonicalFileAcrossNestedProjectsAndAliases() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let project = try project(at: base, name: "Repo", text: "# Shared\nSHARED")
    try FileManager.default.createDirectory(at: project.appendingPathComponent(".git"),
      withIntermediateDirectories: true)
    let child = try self.project(at: project, name: "Child", text: "# Child\nCHILD")
    let alias = base.appendingPathComponent("Alias", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: project)
    let root = base.appendingPathComponent("Data")
    let shared = try XCTUnwrap(PluginStorage.repositorySkills(project: project).first)
    let loaded = try PluginStorage.setRepositorySkillEnabled(false, id: shared.id, project: child, root: root)
    let children = try PluginStorage.repositorySkills(project: child)
    XCTAssertEqual(children.filter { loaded.isSkillEnabled($0) }.map(\.repositoryRoot), [child])
    let aliased = try XCTUnwrap(PluginStorage.repositorySkills(project: alias).first)
    XCTAssertFalse(loaded.isSkillEnabled(aliased))
    try FileManager.default.removeItem(at: shared.fileURL)
    XCTAssertNoThrow(try PluginStorage.load(root: root))
    try Data("# Restored\nRESTORED".utf8).write(to: shared.fileURL)
    XCTAssertFalse(try PluginStorage.load(root: root).isSkillEnabled(shared))
  }

  @MainActor func testRepositoryToggleUpdatesCandidatesTrialsAndSurvivesReload() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let project = try project(at: base, name: "Project", text: "# Review\nREVIEW")
    let store = WorkspaceStore(dataRoot: base.appendingPathComponent("Data"))
    store.libraryLoaded = true
    store.restoringLibrary = false
    store.scopeLoaded = true
    store.project = project
    store.draft = "keep draft"
    await store.loadPlugins()
    let skill = try XCTUnwrap(store.composerSkills.first)
    XCTAssertTrue(store.setSkillEnabled(false, skill: skill))
    XCTAssertFalse(store.isSkillEnabled(skill))
    XCTAssertTrue(store.composerSkills.isEmpty)
    XCTAssertFalse(store.canTrySkill(skill.id))
    XCTAssertFalse(store.trySkill(skill.id))
    XCTAssertTrue(store.library.tasks.isEmpty)
    XCTAssertEqual(store.draft, "keep draft")
    XCTAssertEqual(try store.repositorySkills(for: project.path).map(\.id), [skill.id])
    await store.loadPlugins()
    XCTAssertTrue(store.composerSkills.isEmpty)
    XCTAssertTrue(store.setSkillEnabled(true, skill: skill))
    XCTAssertEqual(store.composerSkills.map(\.id), [skill.id])
    XCTAssertTrue(store.trySkill(skill.id))
    XCTAssertEqual(store.draft, skill.trialPrompt)
  }

  @MainActor func testTrialRechecksExternalRepositoryDisableAndDeletionBeforeCreatingTask() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let project = try project(at: base, name: "Project", text: "# Review\nREVIEW")
    let store = WorkspaceStore(dataRoot: base.appendingPathComponent("Data"))
    store.libraryLoaded = true
    store.restoringLibrary = false
    store.scopeLoaded = true
    store.project = project
    await store.loadPlugins()
    let skill = try XCTUnwrap(store.composerSkills.first)
    _ = try PluginStorage.setRepositorySkillEnabled(false, id: skill.id, project: project, root: store.dataRoot)
    XCTAssertTrue(store.canTrySkill(skill.id)) // Preview has not received the external change yet.
    XCTAssertFalse(store.trySkill(skill.id))
    XCTAssertTrue(store.library.tasks.isEmpty)
    _ = try PluginStorage.setRepositorySkillEnabled(true, id: skill.id, project: project, root: store.dataRoot)
    try FileManager.default.removeItem(at: skill.fileURL)
    XCTAssertFalse(store.trySkill(skill.id))
    XCTAssertFalse(store.setSkillEnabled(false, skill: skill))
    XCTAssertTrue(store.library.tasks.isEmpty)
  }

  func testRepositoryTogglePreferencesAcceptLegacyDataAndRejectMalformedPaths() throws {
    let legacy = try JSONDecoder().decode(PluginPreferences.self, from: Data(#"{"installed":[]}"#.utf8))
    XCTAssertTrue(legacy.disabledRepositorySkillPaths.isEmpty)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    for path in ["relative/SKILL.md", "/tmp/skill/notes.txt", "/tmp/../skill/SKILL.md", "/tmp/\0/SKILL.md"] {
      var preferences = PluginPreferences()
      preferences.disabledRepositorySkillPaths = [path]
      XCTAssertThrowsError(try PluginStorage.save(preferences, root: root))
    }
  }


  @MainActor func testStaleRepositoryToggleCannotChangeUnrelatedOrProjectlessScope() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let first = try project(at: base, name: "First", text: "# Review\nFIRST")
    let second = try project(at: base, name: "Second", text: "# Review\nSECOND")
    let store = WorkspaceStore(dataRoot: base.appendingPathComponent("Data"))
    store.project = first
    await store.loadPlugins()
    let skill = try XCTUnwrap(store.composerSkills.first)
    store.project = second
    XCTAssertFalse(store.setSkillEnabled(false, skill: skill))
    XCTAssertNotNil(store.pluginsError)
    store.project = nil
    XCTAssertFalse(store.setSkillEnabled(false, skill: skill))
    XCTAssertNotNil(store.pluginsError)
    XCTAssertTrue(try PluginStorage.load(root: store.dataRoot).disabledRepositorySkillPaths.isEmpty)
  }

}
