import AppKit
import XCTest
@testable import ShipiOS

final class SkillInterfaceTests: XCTestCase {
  private func fixture(in base: URL, yaml: String) throws -> URL {
    let folder = base.appendingPathComponent("review", isDirectory: true)
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("agents"),
      withIntermediateDirectories: true)
    try Data("---\nname: review\ndescription: Original description\n---\n\nREVIEW-INSTRUCTIONS".utf8)
      .write(to: folder.appendingPathComponent("SKILL.md"))
    try Data(yaml.utf8).write(to: folder.appendingPathComponent("agents/openai.yaml"))
    return folder
  }

  func testYAMLInterfaceOverridesPresentationAndPreservesInstructionsAfterImport() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let folder = try fixture(in: base, yaml: """
      interface:
        display_name: 'Review: Code'
        short_description: >-
          Find defects and
          explain the fixes.
        default_prompt: "Use $review on my changes."
        brand_color: "#3B82F6"
        icon_small: ./assets/icon.svg
      policy:
        allow_implicit_invocation: false
      """)
    let icon = folder.appendingPathComponent("assets/icon.svg")
    try FileManager.default.createDirectory(at: icon.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    let bytes = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"32\" height=\"32\"><rect width=\"32\" height=\"32\" fill=\"red\"/></svg>".utf8)
    try bytes.write(to: icon)
    let root = base.appendingPathComponent("Data")
    let preferences = try PluginStorage.installStandaloneSkill(from: folder, root: root)
    let skill = try XCTUnwrap(PluginStorage.skills(preferences: preferences, root: root).first)
    XCTAssertEqual(skill.title, "Review: Code")
    XCTAssertEqual(skill.summary, "Find defects and explain the fixes.")
    XCTAssertEqual(skill.interface.brandColor, "#3B82F6")
    XCTAssertFalse(skill.interface.allowImplicitInvocation)
    XCTAssertEqual(skill.trialPrompt, "Use \(skill.promptReference) on my changes.")
    let loadedIcon = try XCTUnwrap(skill.interface.iconSmallURL)
    XCTAssertEqual(try PluginStorage.skillIconData(at: loadedIcon,
      in: skill.fileURL.deletingLastPathComponent()), bytes)
    XCTAssertNotNil(NSImage(data: bytes)?.tiffRepresentation)
    XCTAssertTrue(try PluginStorage.promptContext(prompt: skill.trialPrompt,
      preferences: preferences, root: root).instructions.contains("REVIEW-INSTRUCTIONS"))
    let outside = base.appendingPathComponent("outside.svg")
    try bytes.write(to: outside)
    try FileManager.default.removeItem(at: loadedIcon)
    try FileManager.default.createSymbolicLink(at: loadedIcon, withDestinationURL: outside)
    XCTAssertThrowsError(try PluginStorage.skillIconData(at: loadedIcon,
      in: skill.fileURL.deletingLastPathComponent()))
  }

  func testRepositoryDefaultPromptUsesExactReferenceOnceAndDoesNotReplaceLongerName() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let project = base.appendingPathComponent("Project")
    let folder = try fixture(in: project.appendingPathComponent(".agents/skills"), yaml: """
      interface:
        default_prompt: "Use $repo/review for this task. Keep $review-other unchanged."
      """)
    let skill = try XCTUnwrap(PluginStorage.repositorySkills(project: project).first)
    XCTAssertEqual(skill.trialPrompt,
      "Use \(skill.promptReference) for this task. Keep $review-other unchanged.")
    XCTAssertEqual(skill.fileURL.deletingLastPathComponent().resolvingSymlinksInPath().path,
      folder.resolvingSymlinksInPath().path)
    let context = try PluginStorage.promptContext(prompt: skill.trialPrompt,
      preferences: PluginPreferences(), root: base.appendingPathComponent("Data"), repositoryRoot: project)
    XCTAssertEqual(context.skillIDs, [skill.id])
    XCTAssertTrue(context.instructions.contains("REVIEW-INSTRUCTIONS"))
  }

  func testMalformedYAMLAndEscapedIconAreRejectedWithoutReadingExternalFiles() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let folder = try fixture(in: base, yaml: "interface: [broken")
    XCTAssertThrowsError(try PluginStorage.skillInterface(in: folder))
    let yaml = folder.appendingPathComponent("agents/openai.yaml")
    try Data("interface:\n  icon_small: ../../outside.png\n".utf8).write(to: yaml)
    XCTAssertThrowsError(try PluginStorage.skillInterface(in: folder))
    try Data("interface:\n  display_name: Safe\n".utf8).write(to: yaml)
    let external = base.appendingPathComponent("external.yaml")
    try Data("interface:\n  display_name: External\n".utf8).write(to: external)
    try FileManager.default.removeItem(at: yaml)
    try FileManager.default.createSymbolicLink(at: yaml, withDestinationURL: external)
    XCTAssertThrowsError(try PluginStorage.skillInterface(in: folder))
  }

  func testPluginInterfaceUsesQualifiedTrialReferenceWithoutChangingOtherLinks() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let source = base.appendingPathComponent("Plugin")
    _ = try fixture(in: source.appendingPathComponent("skills"), yaml: """
      interface:
        display_name: Plugin Review
        default_prompt: "Use $review. Read [$review](https://example.com/guide) for background."
      """)
    let manifest = source.appendingPathComponent(".codex-plugin/plugin.json")
    try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try Data(#"{"id":"example","name":"Example"}"#.utf8).write(to: manifest)
    let root = base.appendingPathComponent("Data")
    let preferences = try PluginStorage.install(from: source, root: root)
    var skill = try XCTUnwrap(PluginStorage.skills(preferences: preferences, root: root).first)
    XCTAssertEqual(skill.title, "Plugin Review")
    XCTAssertEqual(skill.trialPrompt,
      "Use $example/review. Read [$review](https://example.com/guide) for background.")
    XCTAssertEqual(try PluginStorage.promptContext(prompt: skill.trialPrompt,
      preferences: preferences, root: root).skillIDs, [skill.mention])
    skill.interface.defaultPrompt = "Use $example/review-other instead."
    XCTAssertEqual(skill.trialPrompt, "$example/review Use $example/review-other instead.")
  }

  func testSentencePeriodKeepsExactDottedSkillNameAndDoesNotChooseShorterSkill() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try PluginStorage.createStandaloneSkill(id: "review", description: "Short",
      instructions: "SHORT-INSTRUCTIONS", root: root)
    let preferences = try PluginStorage.createStandaloneSkill(id: "review.v2", description: "Versioned",
      instructions: "VERSIONED-INSTRUCTIONS", root: root)
    let context = try PluginStorage.promptContext(prompt: "Use $review.v2.", preferences: preferences, root: root)
    XCTAssertEqual(context.skillIDs, ["review.v2"])
    XCTAssertTrue(context.instructions.contains("VERSIONED-INSTRUCTIONS"))
    XCTAssertFalse(context.instructions.contains("SHORT-INSTRUCTIONS"))
  }

  @MainActor func testTryNowUsesConfiguredPromptAndKeepsExistingTaskDraft() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let folder = try fixture(in: base, yaml: """
      interface:
        display_name: Friendly Review
        default_prompt: "Review the current changes."
      """)
    let store = WorkspaceStore(dataRoot: base.appendingPathComponent("Data"))
    store.libraryLoaded = true
    store.restoringLibrary = false
    store.scopeLoaded = true
    await store.loadPlugins()
    XCTAssertTrue(store.installStandaloneSkill(from: folder))
    store.draft = "Keep this draft"
    let skill = try XCTUnwrap(store.installedPluginSkills.first)
    XCTAssertTrue(store.trySkill(skill.id))
    XCTAssertEqual(store.draft, skill.promptReference + " Review the current changes.")
    XCTAssertEqual(store.library.drafts["new:none"], "Keep this draft")
    XCTAssertNil(store.modelTask)
  }
}
