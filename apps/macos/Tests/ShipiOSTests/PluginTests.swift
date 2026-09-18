import XCTest

@testable import ShipiOS

final class PluginTests: XCTestCase {
  func testIndividualSkillDisablePersistsAndExcludesPluginAndSkillMentions() throws {
    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    let dataRoot = base.appendingPathComponent("Data")
    let source = try fixture(at: base, skillID: "first", skillText: "# First\nFIRST-INSTRUCTIONS")
    let second = source.appendingPathComponent("skills/second/SKILL.md")
    try FileManager.default.createDirectory(at: second.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("# Second\nSECOND-INSTRUCTIONS".utf8).write(to: second)
    _ = try PluginStorage.install(from: source, root: dataRoot)
    var preferences = try PluginStorage.setSkillEnabled(false, id: "fixture-plugin/first", root: dataRoot)
    XCTAssertEqual(try PluginStorage.load(root: dataRoot), preferences)
    XCTAssertEqual(try PluginStorage.skills(preferences: preferences, root: dataRoot).map(\.skillID), ["second"])
    XCTAssertEqual(try PluginStorage.skills(preferences: preferences, root: dataRoot, includeDisabled: true).count, 2)
    let context = try PluginStorage.promptContext(prompt: "@fixture-plugin $first $fixture-plugin/first",
      preferences: preferences, root: dataRoot)
    XCTAssertFalse(context.instructions.contains("FIRST-INSTRUCTIONS"))
    XCTAssertTrue(context.instructions.contains("SECOND-INSTRUCTIONS"))
    XCTAssertTrue(context.skillIDs.isEmpty)
    preferences = try PluginStorage.setEnabled(false, id: "fixture-plugin", root: dataRoot)
    XCTAssertTrue(try PluginStorage.skills(preferences: preferences, root: dataRoot).isEmpty)
    preferences = try PluginStorage.setEnabled(true, id: "fixture-plugin", root: dataRoot)
    XCTAssertTrue(preferences.disabledSkillIDs.contains("fixture-plugin/first"))
    preferences = try PluginStorage.setSkillEnabled(true, id: "fixture-plugin/first", root: dataRoot)
    XCTAssertEqual(try PluginStorage.skills(preferences: preferences, root: dataRoot).count, 2)
    XCTAssertTrue(try PluginStorage.promptContext(prompt: "$first", preferences: preferences, root: dataRoot)
      .instructions.contains("FIRST-INSTRUCTIONS"))
  }

  func testSkillPreviewReadsDisabledSkillsAndRejectsStaleOrEscapedFiles() throws {
    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    let dataRoot = base.appendingPathComponent("Data")
    _ = try PluginStorage.install(from: fixture(at: base, skillText: "# Preview\nActual source"), root: dataRoot)
    _ = try PluginStorage.setSkillEnabled(false, id: "fixture-plugin/example", root: dataRoot)
    XCTAssertEqual(try PluginStorage.readSkill(id: "fixture-plugin/example", root: dataRoot), "# Preview\nActual source")
    let before = try Data(contentsOf: dataRoot.appendingPathComponent("plugins.json"))
    XCTAssertThrowsError(try PluginStorage.setSkillEnabled(true, id: "fixture-plugin/missing", root: dataRoot))
    XCTAssertThrowsError(try PluginStorage.readSkill(id: "../outside", root: dataRoot))
    XCTAssertEqual(try Data(contentsOf: dataRoot.appendingPathComponent("plugins.json")), before)
    let directory = PluginStorage.packageURL(root: dataRoot, id: "fixture-plugin").appendingPathComponent("skills/example")
    let external = base.appendingPathComponent("External")
    try FileManager.default.moveItem(at: directory, to: external)
    try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: external)
    XCTAssertThrowsError(try PluginStorage.readSkill(id: "fixture-plugin/example", root: dataRoot))
  }

  func testLegacySkillPreferencesAndPluginRemovalCleanIndividualOverrides() throws {
    let legacy = try JSONDecoder().decode(PluginPreferences.self, from: Data(#"{"installed":[]}"#.utf8))
    XCTAssertTrue(legacy.disabledSkillIDs.isEmpty)
    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    let dataRoot = base.appendingPathComponent("Data")
    _ = try PluginStorage.install(from: fixture(at: base), root: dataRoot)
    _ = try PluginStorage.setSkillEnabled(false, id: "fixture-plugin/example", root: dataRoot)
    let removed = try PluginStorage.remove(id: "fixture-plugin", root: dataRoot)
    XCTAssertTrue(removed.disabledSkillIDs.isEmpty)
    XCTAssertThrowsError(try PluginStorage.readSkill(id: "fixture-plugin/example", root: dataRoot))
  }

  @MainActor func testSkillManagementRefreshesCandidatesAndKeepsDisabledRowsAcrossReload() async throws {
    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    let store = WorkspaceStore(dataRoot: base.appendingPathComponent("Data"))
    await store.loadPlugins()
    XCTAssertTrue(store.installPlugin(from: try fixture(at: base)))
    XCTAssertEqual(store.pluginSkills.count, 1)
    XCTAssertTrue(store.setSkillEnabled(false, id: "fixture-plugin/example"))
    XCTAssertTrue(store.pluginSkills.isEmpty)
    XCTAssertEqual(store.installedPluginSkills.count, 1)
    await store.loadPlugins()
    XCTAssertTrue(store.pluginSkills.isEmpty)
    XCTAssertEqual(store.installedPluginSkills.count, 1)
    XCTAssertTrue(store.setSkillEnabled(true, id: "fixture-plugin/example"))
    XCTAssertEqual(store.pluginSkills.count, 1)
  }

  private func root() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }

  private func fixture(
    at root: URL, id: String = "fixture-plugin", sourceName: String = "Source",
    skillID: String = "example", skillText: String = "# Example"
  ) throws -> URL {
    let source = root.appendingPathComponent(sourceName, isDirectory: true)
    let manifest = source.appendingPathComponent(".codex-plugin/plugin.json")
    try FileManager.default.createDirectory(
      at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
    let object: [String: Any] = [
      "id": id,
      "name": "Fixture Plugin",
      "description": "A local test plugin",
      "version": "1.2.3",
      "mcp_servers": ["fixture": ["command": "fixture"]],
    ]
    try JSONSerialization.data(withJSONObject: object).write(to: manifest)
    let skill = source.appendingPathComponent("skills/\(skillID)/SKILL.md")
    try FileManager.default.createDirectory(
      at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(skillText.utf8).write(to: skill)
    let hook = source.appendingPathComponent("hooks/hooks.json")
    try FileManager.default.createDirectory(
      at: hook.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: hook)
    return source
  }

  func testInstallTogglePersistenceAndRemovalStayInIndependentRoot() throws {
    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    let source = try fixture(at: base)
    let dataRoot = base.appendingPathComponent("Data")
    let installedAt = Date(timeIntervalSince1970: 1_800_000_000)
    var preferences = try PluginStorage.install(from: source, root: dataRoot, now: installedAt)
    XCTAssertEqual(preferences.installed.count, 1)
    let plugin = try XCTUnwrap(preferences.installed.first)
    XCTAssertEqual(plugin.id, "fixture-plugin")
    XCTAssertEqual(plugin.name, "Fixture Plugin")
    XCTAssertEqual(plugin.version, "1.2.3")
    XCTAssertEqual(plugin.installedAt, installedAt)
    XCTAssertEqual(plugin.components.skills, 1)
    XCTAssertEqual(plugin.components.mcpServers, 1)
    XCTAssertTrue(plugin.components.hasHooks)
    XCTAssertTrue(plugin.enabled)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: PluginStorage.packageURL(root: dataRoot, id: plugin.id).path))
    let attributes = try FileManager.default.attributesOfItem(
      atPath: dataRoot.appendingPathComponent("plugins.json").path)
    XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)

    let context = try PluginStorage.promptContext(
      prompt: "Use @fixture-plugin for this task", preferences: preferences, root: dataRoot)
    XCTAssertEqual(context.ids, ["fixture-plugin"])
    XCTAssertTrue(context.skillIDs.isEmpty)
    XCTAssertTrue(context.instructions.contains("# Example"))
    XCTAssertTrue(context.instructions.contains("Fixture Plugin"))
    XCTAssertTrue(
      try PluginStorage.promptContext(
        prompt: "No explicit invocation", preferences: preferences, root: dataRoot
      ).instructions.isEmpty)

    preferences = try PluginStorage.setEnabled(false, id: plugin.id, root: dataRoot)
    XCTAssertFalse(preferences.installed[0].enabled)
    XCTAssertTrue(
      try PluginStorage.promptContext(
        prompt: "Use @fixture-plugin", preferences: preferences, root: dataRoot
      ).instructions.isEmpty)
    XCTAssertEqual(try PluginStorage.load(root: dataRoot), preferences)
    preferences = try PluginStorage.remove(id: plugin.id, root: dataRoot)
    XCTAssertTrue(preferences.installed.isEmpty)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: PluginStorage.packageURL(root: dataRoot, id: plugin.id).path))
  }

  func testInvalidIdentifierDuplicateAndSymlinkAreRejectedWithoutCorruptingState() throws {
    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    let dataRoot = base.appendingPathComponent("Data")
    XCTAssertThrowsError(
      try PluginStorage.install(from: fixture(at: base, id: "bad/id"), root: dataRoot))
    XCTAssertTrue(try PluginStorage.load(root: dataRoot).installed.isEmpty)

    try FileManager.default.removeItem(at: base.appendingPathComponent("Source"))
    let source = try fixture(at: base)
    _ = try PluginStorage.install(from: source, root: dataRoot)
    XCTAssertThrowsError(try PluginStorage.install(from: source, root: dataRoot))
    XCTAssertEqual(try PluginStorage.load(root: dataRoot).installed.count, 1)

    let symlinkRoot = base.appendingPathComponent("SymlinkFixture")
    let linkedSource = try fixture(at: symlinkRoot, id: "linked-plugin")
    try FileManager.default.createSymbolicLink(
      at: linkedSource.appendingPathComponent("linked"), withDestinationURL: source)
    XCTAssertThrowsError(try PluginStorage.inspect(source: linkedSource))
  }

  @MainActor func testPluginPageSlashCommandAndSettingsReturnPreserveWorkspace() async throws {
    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    let store = WorkspaceStore(dataRoot: base.appendingPathComponent("Data"))
    await store.loadPlugins()
    XCTAssertTrue(store.pluginsLoaded)
    store.draft = "keep me"
    store.executeCommand("plugins")
    XCTAssertEqual(store.destination, .plugins)
    XCTAssertTrue(store.retainsPluginsPage)
    store.openSettings(.appearance)
    XCTAssertEqual(store.destination, .settings)
    XCTAssertTrue(store.retainsPluginsPage)
    store.closeSettings()
    XCTAssertEqual(store.destination, .plugins)
    await store.navigate(back: true)
    XCTAssertEqual(store.destination, .workspace)
    XCTAssertEqual(store.draft, "keep me")

    var selection = ComposerCommandSelection()
    selection.update(draft: "/plug", enabled: store.enabledComposerCommands)
    XCTAssertEqual(selection.matches, [.plugins])
    store.selectComposerCommand(.plugins)
    XCTAssertEqual(store.destination, .plugins)
    XCTAssertEqual(store.draft, "")
  }

  func testMentionSelectionFiltersEnabledPluginsAndReplacesOnlyTrailingToken() {
    let enabled = PluginInstallation(
      id: "fixture-plugin", name: "Fixture Plugin", summary: "", version: "1",
      enabled: true, installedAt: Date(), components: PluginComponents(skills: 1))
    let disabled = PluginInstallation(
      id: "disabled-plugin", name: "Disabled Plugin", summary: "", version: "1",
      enabled: false, installedAt: Date(), components: PluginComponents())
    var selection = PluginMentionSelection()
    selection.update(draft: "Please use @fix", plugins: [enabled, disabled])
    XCTAssertEqual(selection.matches, [enabled])
    XCTAssertEqual(selection.handle(.accept), .accept(enabled))
    XCTAssertEqual(
      PluginMentionSelection.replacingTrailingMention(
        in: "Please use @fix", plugin: enabled),
      "Please use @fixture-plugin ")
    selection.update(draft: "email@example.com", plugins: [enabled])
    XCTAssertFalse(selection.isVisible)
    selection.update(draft: "@", plugins: [enabled, disabled])
    XCTAssertEqual(selection.matches, [enabled])
  }

  func testSkillDiscoverySelectionAndExplicitContextHandleDuplicateNames() throws {
    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    let dataRoot = base.appendingPathComponent("Data")
    var preferences = try PluginStorage.install(
      from: fixture(
        at: base, id: "alpha-plugin", sourceName: "Alpha", skillID: "review",
        skillText: "---\nname: Alpha Review\n---\nALPHA-ONLY"),
      root: dataRoot)
    preferences = try PluginStorage.install(
      from: fixture(
        at: base, id: "beta-plugin", sourceName: "Beta", skillID: "review",
        skillText: "# Beta Review\nBETA-ONLY"),
      root: dataRoot)

    let skills = try PluginStorage.skills(preferences: preferences, root: dataRoot)
    XCTAssertEqual(skills.map(\.mention), ["alpha-plugin/review", "beta-plugin/review"])
    XCTAssertEqual(skills.map(\.title), ["Alpha Review", "Beta Review"])

    var selection = SkillMentionSelection()
    selection.update(draft: "Please $alpha", skills: skills)
    let alpha = try XCTUnwrap(selection.matches.first)
    XCTAssertEqual(selection.handle(.accept), .accept(alpha))
    XCTAssertEqual(
      SkillMentionSelection.replacingTrailingMention(in: "Please $alpha", skill: alpha),
      "Please $alpha-plugin/review ")
    selection.update(draft: "cost$alpha", skills: skills)
    XCTAssertFalse(selection.isVisible)

    let ambiguous = try PluginStorage.promptContext(
      prompt: "Use $review", preferences: preferences, root: dataRoot)
    XCTAssertTrue(ambiguous.ids.isEmpty)
    XCTAssertTrue(ambiguous.instructions.isEmpty)

    let context = try PluginStorage.promptContext(
      prompt: "Use $alpha-plugin/review", preferences: preferences, root: dataRoot)
    XCTAssertEqual(context.ids, ["alpha-plugin"])
    XCTAssertEqual(context.skillIDs, ["alpha-plugin/review"])
    XCTAssertTrue(context.instructions.contains("ALPHA-ONLY"))
    XCTAssertFalse(context.instructions.contains("BETA-ONLY"))
  }
}
