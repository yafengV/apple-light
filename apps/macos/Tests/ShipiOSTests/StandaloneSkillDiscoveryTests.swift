import XCTest
@testable import ShipiOS

final class StandaloneSkillDiscoveryTests: XCTestCase {
  private func writeSkill(root: URL, id: String = "review") throws -> URL {
    let file = root.appendingPathComponent("Skills/\(id)/SKILL.md")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("---\nname: Auto Review\ndescription: Inspect the project\n---\n\nAUTO-INSTRUCTIONS".utf8).write(to: file)
    return file
  }

  func testUnregisteredPrivateFoldersAreDiscoveredWithoutChangingFilesOrPreferences() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.appendingPathComponent("Data")
    let file = try writeSkill(root: root)
    _ = try writeSkill(root: base.appendingPathComponent("PersonalCodex"), id: "unrelated")
    _ = try writeSkill(root: root, id: ".install-staging")
    let original = try Data(contentsOf: file)
    let preferences = try PluginStorage.load(root: root)
    let skills = try PluginStorage.skills(preferences: preferences, root: root)
    XCTAssertEqual(skills.map(\.id), ["user:review"])
    XCTAssertEqual(skills.first?.title, "Auto Review")
    XCTAssertEqual(skills.first?.summary, "Inspect the project")
    XCTAssertTrue(preferences.standaloneSkills.isEmpty)
    XCTAssertEqual(try Data(contentsOf: file), original)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("plugins.json").path))
    XCTAssertTrue(try PluginStorage.promptContext(prompt: "$review", preferences: preferences, root: root)
      .instructions.contains("AUTO-INSTRUCTIONS"))
    XCTAssertEqual(try PluginStorage.discoveryContext(preferences: preferences, root: root,
      repositoryRoot: nil, readTool: true).skills.map(\.id), ["user:review"])
  }

  func testUnregisteredSkillCanBeEditedAndRemovedWithoutPriorImport() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try writeSkill(root: root)
    let resource = file.deletingLastPathComponent().appendingPathComponent("notes.txt")
    try Data("keep resource".utf8).write(to: resource)
    let original = try String(contentsOf: file)
    try PluginStorage.updateStandaloneSkill(id: "user:review", text: "# Updated\nUpdated instructions",
      expectedOriginal: original, root: root)
    XCTAssertEqual(try String(contentsOf: resource), "keep resource")
    XCTAssertTrue(try PluginStorage.load(root: root).standaloneSkills.isEmpty)
    XCTAssertThrowsError(try PluginStorage.updateStandaloneSkill(id: "user:review", text: "stale",
      expectedOriginal: original, root: root))
    let removed = try PluginStorage.removeStandaloneSkill(id: "user:review", root: root)
    XCTAssertTrue(removed.standaloneSkills.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
    XCTAssertTrue(try PluginStorage.skills(preferences: removed, root: root).isEmpty)
  }

  func testToggleAdoptsDiscoveredSkillAndPersistsDisabledStateAcrossDeletionAndRecreation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try writeSkill(root: root)
    let disabled = try PluginStorage.setSkillEnabled(false, id: "user:review", root: root)
    XCTAssertEqual(disabled.standaloneSkills, ["review"])
    XCTAssertTrue(disabled.disabledSkillIDs.contains("user:review"))
    XCTAssertTrue(try PluginStorage.skills(preferences: disabled, root: root).isEmpty)
    XCTAssertEqual(try PluginStorage.skills(preferences: disabled, root: root, includeDisabled: true).count, 1)
    try FileManager.default.removeItem(at: file.deletingLastPathComponent())
    XCTAssertNoThrow(try PluginStorage.load(root: root))
    let restored = try PluginStorage.createStandaloneSkill(id: "Review", description: "Restored",
      instructions: "RESTORED-INSTRUCTIONS", root: root)
    XCTAssertEqual(restored.standaloneSkills, ["Review"])
    XCTAssertEqual(restored.disabledSkillIDs, ["user:Review"])
    XCTAssertTrue(try PluginStorage.skills(preferences: restored, root: root).isEmpty)
    let enabled = try PluginStorage.setSkillEnabled(true, id: "user:Review", root: root)
    XCTAssertEqual(try PluginStorage.skills(preferences: enabled, root: root).map(\.id), ["user:Review"])
  }

  func testCreateAndImportDoNotOverwriteAutomaticallyDiscoveredFolders() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.appendingPathComponent("Data")
    let file = try writeSkill(root: root)
    let original = try Data(contentsOf: file)
    XCTAssertThrowsError(try PluginStorage.createStandaloneSkill(id: "REVIEW", description: "Duplicate",
      instructions: "Replace", root: root))
    let source = base.appendingPathComponent("Source/review")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("# Imported\nReplace".utf8).write(to: source.appendingPathComponent("SKILL.md"))
    XCTAssertThrowsError(try PluginStorage.installStandaloneSkill(from: source, root: root))
    XCTAssertEqual(try Data(contentsOf: file), original)
    XCTAssertTrue(try PluginStorage.load(root: root).standaloneSkills.isEmpty)
  }

  func testCaseOnlyExternalRenamePreservesDisabledStateAndCanBeEditedToggledAndRemoved() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try writeSkill(root: root)
    _ = try PluginStorage.setSkillEnabled(false, id: "user:review", root: root)
    let staging = root.appendingPathComponent("Skills/.rename")
    let renamed = root.appendingPathComponent("Skills/Review")
    try FileManager.default.moveItem(at: file.deletingLastPathComponent(), to: staging)
    try FileManager.default.moveItem(at: staging, to: renamed)
    let preferences = try PluginStorage.load(root: root)
    let skill = try XCTUnwrap(PluginStorage.skills(preferences: preferences, root: root,
      includeDisabled: true).first)
    XCTAssertEqual(skill.id, "user:Review")
    XCTAssertFalse(preferences.isSkillEnabled(skill))
    XCTAssertTrue(try PluginStorage.skills(preferences: preferences, root: root).isEmpty)
    let original = try String(contentsOf: renamed.appendingPathComponent("SKILL.md"))
    try PluginStorage.updateStandaloneSkill(id: skill.id, text: "# Renamed\nUPDATED",
      expectedOriginal: original, root: root)
    let enabled = try PluginStorage.setSkillEnabled(true, id: skill.id, root: root)
    XCTAssertEqual(enabled.standaloneSkills, ["Review"])
    XCTAssertTrue(enabled.disabledSkillIDs.isEmpty)
    _ = try PluginStorage.setSkillEnabled(false, id: skill.id, root: root)
    try FileManager.default.moveItem(at: renamed, to: staging)
    try FileManager.default.moveItem(at: staging, to: file.deletingLastPathComponent())
    let removed = try PluginStorage.removeStandaloneSkill(id: "user:review", root: root)
    XCTAssertTrue(removed.standaloneSkills.isEmpty)
    XCTAssertTrue(removed.disabledSkillIDs.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
  }

  func testAutomaticDiscoverySkipsUnregisteredLinksAndRejectsLinkedSkillFileAndRoot() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let external = base.appendingPathComponent("External")
    let outside = try writeSkill(root: external)
    let root = base.appendingPathComponent("Data")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Skills"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Skills/linked"),
      withDestinationURL: outside.deletingLastPathComponent())
    XCTAssertTrue(try PluginStorage.skills(preferences: PluginPreferences(), root: root).isEmpty)
    let folder = root.appendingPathComponent("Skills/review")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("SKILL.md"), withDestinationURL: outside)
    XCTAssertThrowsError(try PluginStorage.skills(preferences: PluginPreferences(), root: root))
    let other = base.appendingPathComponent("LinkedRoot")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: other.appendingPathComponent("Skills"),
      withDestinationURL: external.appendingPathComponent("Skills"))
    XCTAssertThrowsError(try PluginStorage.skills(preferences: PluginPreferences(), root: other))
  }

  @MainActor func testExternalPrivateSkillAppearsUpdatesAndDisappearsThroughAutomaticRefresh() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true; store.restoringLibrary = false; store.scopeLoaded = true
    await store.loadPlugins()
    await store.refreshSkillsIfChanged()
    XCTAssertEqual(store.pluginSettingsCount(.skills), 0)
    store.draft = "keep my draft"
    let file = try writeSkill(root: root)
    await store.refreshSkillsIfChanged()
    XCTAssertEqual(store.installedPluginSkills.map(\.id), ["user:review"])
    XCTAssertEqual(store.composerSkills.map(\.id), ["user:review"])
    XCTAssertEqual(store.pluginSettingsCount(.skills), 1)
    XCTAssertTrue(store.pluginPreferences.standaloneSkills.isEmpty)
    XCTAssertTrue(store.trySkill("user:review"))
    XCTAssertEqual(store.library.drafts["new:none"], "keep my draft")
    let original = try String(contentsOf: file)
    XCTAssertTrue(store.updateStandaloneSkill(id: "user:review", text: "# Updated\nNew instructions", expectedOriginal: original))
    XCTAssertEqual(store.composerSkills.first?.title, "Updated")
    XCTAssertTrue(store.setSkillEnabled(false, id: "user:review"))
    XCTAssertEqual(store.pluginSettingsCount(.skills), 1)
    XCTAssertTrue(store.composerSkills.isEmpty)
    try FileManager.default.removeItem(at: file)
    await store.refreshSkillsIfChanged()
    XCTAssertTrue(store.pluginsLoaded)
    XCTAssertEqual(store.pluginSettingsCount(.skills), 0)
    XCTAssertTrue(store.installedPluginSkills.isEmpty)
    try Data(original.utf8).write(to: file)
    await store.refreshSkillsIfChanged()
    XCTAssertEqual(store.pluginSettingsCount(.skills), 1)
    XCTAssertTrue(store.composerSkills.isEmpty, "Restored file retains its disabled state")
    XCTAssertTrue(store.removeStandaloneSkill("user:review"))
    XCTAssertEqual(store.pluginSettingsCount(.skills), 0)
  }
}
