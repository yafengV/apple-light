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
    XCTAssertEqual(firstSkill.id, "repo:review")
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
    XCTAssertEqual(firstContext.skillIDs, ["repo/review"])
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
    XCTAssertEqual(store.composerSkills.map(\.id), ["repo:review"])
    XCTAssertEqual(store.composerSkills(for: second.path).first?.title, "Second Review")
    XCTAssertTrue(store.trySkill("repo:review"))
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
}
