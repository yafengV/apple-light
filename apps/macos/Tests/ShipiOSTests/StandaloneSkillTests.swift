import XCTest
@testable import ShipiOS

final class StandaloneSkillTests: XCTestCase {
  private func fixture(_ base: URL, name: String = "review") throws -> URL {
    let source = base.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: source.appendingPathComponent("references"), withIntermediateDirectories: true)
    try Data("# Local Review\nLOCAL-INSTRUCTIONS".utf8).write(to: source.appendingPathComponent("SKILL.md"))
    try Data("resource".utf8).write(to: source.appendingPathComponent("references/notes.txt"))
    return source
  }

  func testImportDisablePreviewAndRemovalPreserveOriginalFolder() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let source = try fixture(base)
    let root = base.appendingPathComponent("Data (test)")
    var preferences = try PluginStorage.installStandaloneSkill(from: source, root: root)
    XCTAssertTrue(preferences.installed.isEmpty)
    XCTAssertEqual(preferences.standaloneSkills, ["review"])
    XCTAssertEqual(try PluginStorage.load(root: root), preferences)
    let skill = try XCTUnwrap(PluginStorage.skills(preferences: preferences, root: root).first)
    XCTAssertEqual(skill.id, "user:review")
    XCTAssertTrue(skill.isStandalone)
    XCTAssertEqual(try String(contentsOf: skill.fileURL.deletingLastPathComponent().appendingPathComponent("references/notes.txt")), "resource")
    let context = try PluginStorage.promptContext(prompt: skill.promptReference, preferences: preferences, root: root)
    XCTAssertTrue(context.ids.isEmpty)
    XCTAssertEqual(context.skillIDs, ["review"])
    XCTAssertTrue(context.instructions.contains("LOCAL-INSTRUCTIONS"))
    XCTAssertEqual(SkillMentionSelection.replacingTrailingMention(in: "Please $rev", skill: skill), "Please " + skill.promptReference + " ")
    XCTAssertTrue(try PluginStorage.promptContext(prompt: "$review", preferences: preferences, root: root).instructions.contains("LOCAL-INSTRUCTIONS"))
    preferences = try PluginStorage.setSkillEnabled(false, id: skill.id, root: root)
    XCTAssertTrue(try PluginStorage.skills(preferences: preferences, root: root).isEmpty)
    XCTAssertEqual(try PluginStorage.skills(preferences: preferences, root: root, includeDisabled: true).count, 1)
    XCTAssertTrue(try PluginStorage.readSkill(id: skill.id, root: root).contains("LOCAL-INSTRUCTIONS"))
    XCTAssertTrue(try PluginStorage.promptContext(prompt: skill.promptReference + " $review", preferences: preferences, root: root).instructions.isEmpty)
    preferences = try PluginStorage.removeStandaloneSkill(id: skill.id, root: root)
    XCTAssertTrue(preferences.standaloneSkills.isEmpty)
    XCTAssertTrue(preferences.disabledSkillIDs.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: skill.fileURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("references/notes.txt").path))
    XCTAssertThrowsError(try PluginStorage.readSkill(id: skill.id, root: root))
    XCTAssertThrowsError(try PluginStorage.removeStandaloneSkill(id: "plugin/review", root: root))
  }

  func testDuplicateNamesRequireExactRegisteredReference() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let source = try fixture(base)
    let root = base.appendingPathComponent("Data (test)")
    _ = try PluginStorage.installStandaloneSkill(from: source, root: root)
    let plugin = base.appendingPathComponent("Plugin")
    let manifest = plugin.appendingPathComponent(".codex-plugin/plugin.json")
    try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"id":"example","name":"Example"}"#.utf8).write(to: manifest)
    let packaged = plugin.appendingPathComponent("skills/review/SKILL.md")
    try FileManager.default.createDirectory(at: packaged.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("# Packaged Review\nPACKAGED-INSTRUCTIONS".utf8).write(to: packaged)
    let preferences = try PluginStorage.install(from: plugin, root: root)
    let skills = try PluginStorage.skills(preferences: preferences, root: root)
    let local = try XCTUnwrap(skills.first { $0.isStandalone })
    XCTAssertEqual(skills.first { !$0.isStandalone }?.mention, "example/review")
    XCTAssertTrue(try PluginStorage.promptContext(prompt: "$review", preferences: preferences, root: root).instructions.isEmpty)
    let context = try PluginStorage.promptContext(prompt: local.promptReference, preferences: preferences, root: root)
    XCTAssertTrue(context.instructions.contains("LOCAL-INSTRUCTIONS"))
    XCTAssertFalse(context.instructions.contains("PACKAGED-INSTRUCTIONS"))
    XCTAssertTrue(context.ids.isEmpty)
    let packagedContext = try PluginStorage.promptContext(prompt: "$example/review", preferences: preferences, root: root)
    XCTAssertFalse(packagedContext.instructions.contains("LOCAL-INSTRUCTIONS"))
    XCTAssertTrue(packagedContext.instructions.contains("PACKAGED-INSTRUCTIONS"))
    for link in ["[$review](https://example.com/SKILL.md)", "[$review](file:///tmp/unregistered/SKILL.md)", "[$unknown](\(local.fileURL.absoluteString))"] {
      XCTAssertTrue(try PluginStorage.promptContext(prompt: link, preferences: preferences, root: root).instructions.isEmpty)
    }
    let removed = try PluginStorage.removeStandaloneSkill(id: local.id, root: root)
    XCTAssertEqual(removed.installed.count, 1)
    XCTAssertTrue(try PluginStorage.promptContext(prompt: "$review", preferences: removed, root: root).instructions.contains("PACKAGED-INSTRUCTIONS"))
  }

  func testInvalidSourceDuplicateAndEscapedStorageAreRejected() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let source = try fixture(base)
    let root = base.appendingPathComponent("Data")
    let preferences = try PluginStorage.installStandaloneSkill(from: source, root: root)
    XCTAssertThrowsError(try PluginStorage.installStandaloneSkill(from: source, root: root))
    let missing = base.appendingPathComponent("missing")
    try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
    XCTAssertThrowsError(try PluginStorage.installStandaloneSkill(from: missing, root: root))
    let linked = try fixture(base, name: "linked")
    try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("link"), withDestinationURL: source)
    XCTAssertThrowsError(try PluginStorage.installStandaloneSkill(from: linked, root: root))
    let invalid = try fixture(base, name: "invalid")
    try Data([0xff, 0xfe]).write(to: invalid.appendingPathComponent("SKILL.md"))
    XCTAssertThrowsError(try PluginStorage.installStandaloneSkill(from: invalid, root: root))
    XCTAssertEqual(try PluginStorage.load(root: root), preferences)
    let installed = PluginStorage.standaloneSkillURL(root: root, id: "review")
    try FileManager.default.removeItem(at: installed)
    try FileManager.default.createSymbolicLink(at: installed, withDestinationURL: source)
    XCTAssertThrowsError(try PluginStorage.readSkill(id: "user:review", root: root))
    _ = try PluginStorage.removeStandaloneSkill(id: "user:review", root: root)
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("SKILL.md").path))
  }

  @MainActor func testSettingsTrialReloadAndUninstallKeepIndependentDrafts() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let source = try fixture(base)
    let store = WorkspaceStore(dataRoot: base.appendingPathComponent("Data"))
    store.libraryLoaded = true
    store.restoringLibrary = false
    store.scopeLoaded = true
    await store.loadPlugins()
    XCTAssertEqual(store.visiblePluginSettingsSections, [.mcpServers])
    XCTAssertTrue(store.installStandaloneSkill(from: source))
    XCTAssertEqual(store.visiblePluginSettingsSections, [.mcpServers, .skills])
    XCTAssertEqual(store.activePluginSettingsSection, .skills)
    XCTAssertEqual(PluginSettingsSection.skills.count(in: [], standaloneSkills: 1), 1)
    let skill = try XCTUnwrap(store.composerSkills.first)
    store.draft = "原草稿"
    store.openSettings(.skills)
    XCTAssertTrue(store.trySkill(skill.id))
    XCTAssertEqual(store.draft, skill.promptReference + " ")
    XCTAssertEqual(store.library.drafts["new:none"], "原草稿")
    XCTAssertNil(store.modelTask)
    await store.loadPlugins()
    XCTAssertEqual(store.composerSkills.map(\.id), [skill.id])
    XCTAssertTrue(store.removeStandaloneSkill(skill.id))
    XCTAssertTrue(store.composerSkills.isEmpty)
    XCTAssertTrue(store.installedPluginSkills.isEmpty)
    XCTAssertEqual(store.visiblePluginSettingsSections, [.mcpServers])
    XCTAssertFalse(store.trySkill(skill.id))
    XCTAssertEqual(store.draft, skill.promptReference + " ")
    XCTAssertEqual(store.library.tasks.count, 1)
  }

  func testLegacyPreferencesDoNotInventStandaloneSkills() throws {
    let legacy = try JSONDecoder().decode(PluginPreferences.self, from: Data(#"{"installed":[]}"#.utf8))
    XCTAssertTrue(legacy.standaloneSkills.isEmpty)
    XCTAssertTrue(legacy.disabledSkillIDs.isEmpty)
  }
}
