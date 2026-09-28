import XCTest
@testable import ShipiOS

final class LinkedSkillTests: XCTestCase {
  private func writeSkill(_ folder: URL, text: String = "LINKED-INSTRUCTIONS") throws -> URL {
    let file = folder.appendingPathComponent("SKILL.md")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("---\nname: Shared Review\ndescription: Inspect shared changes\n---\n\n\(text)".utf8).write(to: file)
    return file
  }

  private func link(_ url: URL, target: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
  }

  func testPrivateAndRepositoryLinksLoadMetadataResourcesAndScopedInstructions() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let target = base.appendingPathComponent("Shared/review")
    let file = try writeSkill(target)
    let yaml = target.appendingPathComponent("agents/openai.yaml")
    try FileManager.default.createDirectory(at: yaml.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("interface:\n  display_name: Linked Display\n  icon_small: icon.png\n  default_prompt: Try $review\n".utf8).write(to: yaml)
    try Data([1, 2, 3]).write(to: target.appendingPathComponent("icon.png"))
    let data = base.appendingPathComponent("Data"), project = base.appendingPathComponent("Project")
    try link(data.appendingPathComponent("Skills/review"), target: target)
    let projectLink = project.appendingPathComponent(".agents/skills/review")
    try FileManager.default.createDirectory(at: projectLink.deletingLastPathComponent(), withIntermediateDirectories: true)
    // Relative folder links resolve against their own parent, not the process working directory.
    try FileManager.default.createSymbolicLink(atPath: projectLink.path, withDestinationPath: "../../../Shared/review")
    let preferences = try PluginStorage.load(root: data)
    let personal = try XCTUnwrap(PluginStorage.skills(preferences: preferences, root: data).first)
    let repository = try XCTUnwrap(PluginStorage.repositorySkills(project: project).first)
    XCTAssertEqual(personal.id, "user:review")
    XCTAssertEqual(repository.id, "repo:" + project.path + "/review")
    XCTAssertNotEqual(personal.id, repository.id)
    for skill in [personal, repository] {
      XCTAssertTrue(skill.isLinkedSource)
      XCTAssertEqual(skill.sourceFileURL.path, file.resolvingSymlinksInPath().path)
      XCTAssertEqual(skill.title, "Linked Display")
      XCTAssertTrue(skill.trialPrompt.contains(skill.promptReference))
      let icon = try XCTUnwrap(skill.interface.iconSmallURL)
      XCTAssertEqual(try PluginStorage.skillIconData(at: icon, in: skill.sourceFileURL.deletingLastPathComponent()), Data([1, 2, 3]))
      let document = try PluginStorage.readSkillDocument(id: skill.id, root: data, repositoryRoot: project)
      XCTAssertTrue(document.text.contains("LINKED-INSTRUCTIONS"))
      XCTAssertEqual(document.fileURL, skill.sourceFileURL)
      XCTAssertTrue(document.isLinkedSource)
      XCTAssertTrue(try PluginStorage.promptContext(prompt: skill.promptReference, preferences: preferences,
        root: data, repositoryRoot: project).instructions.contains("LINKED-INSTRUCTIONS"))
    }
    XCTAssertEqual(try PluginStorage.discoveryContext(preferences: preferences, root: data,
      repositoryRoot: project, readTool: true).skills.count, 2)
    XCTAssertThrowsError(try PluginStorage.readSkill(id: repository.id, root: data))
    XCTAssertTrue(try PluginStorage.repositorySkills(project: base.appendingPathComponent("Other")).isEmpty)
    XCTAssertTrue(preferences.standaloneSkills.isEmpty)
  }

  func testLinkedSkillEditChangesTargetPreservesResourcesAndRejectsRetargetedDocument() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let first = base.appendingPathComponent("First"), second = base.appendingPathComponent("Second")
    let firstFile = try writeSkill(first), secondFile = try writeSkill(second)
    let resource = first.appendingPathComponent("notes.txt")
    try Data("keep".utf8).write(to: resource)
    let root = base.appendingPathComponent("Data"), project = base.appendingPathComponent("Project")
    let privateLink = root.appendingPathComponent("Skills/review")
    let repositoryLink = project.appendingPathComponent(".agents/skills/review")
    try link(privateLink, target: first); try link(repositoryLink, target: first)
    let original = try String(contentsOf: firstFile)
    try PluginStorage.updateStandaloneSkill(id: "user:review", text: "# Updated\nUPDATED",
      expectedOriginal: original, root: root, expectedFileURL: firstFile.resolvingSymlinksInPath())
    XCTAssertEqual(try String(contentsOf: firstFile), "# Updated\nUPDATED")
    XCTAssertEqual(try String(contentsOf: resource), "keep")
    XCTAssertTrue(try privateLink.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    let id = "repo:" + project.path + "/review"
    try PluginStorage.updateRepositorySkill(id: id, text: original, expectedOriginal: "# Updated\nUPDATED",
      project: project, expectedFileURL: firstFile.resolvingSymlinksInPath())
    XCTAssertEqual(try String(contentsOf: firstFile), original)
    for url in [privateLink, repositoryLink] {
      try FileManager.default.removeItem(at: url); try link(url, target: second)
    }
    XCTAssertThrowsError(try PluginStorage.updateStandaloneSkill(id: "user:review", text: "WRONG",
      expectedOriginal: original, root: root, expectedFileURL: firstFile.resolvingSymlinksInPath()))
    XCTAssertThrowsError(try PluginStorage.updateRepositorySkill(id: id, text: "WRONG",
      expectedOriginal: original, project: project, expectedFileURL: firstFile.resolvingSymlinksInPath()))
    XCTAssertEqual(try String(contentsOf: secondFile), original)
    let reloaded = try PluginStorage.readSkillDocument(id: "user:review", root: root)
    XCTAssertTrue(reloaded.isLinkedSource)
    XCTAssertEqual(reloaded.fileURL, secondFile.resolvingSymlinksInPath())
    try PluginStorage.updateStandaloneSkill(id: "user:review", text: "# New Target\nUPDATED",
      expectedOriginal: reloaded.text, root: root, expectedFileURL: reloaded.fileURL)
    XCTAssertEqual(try String(contentsOf: secondFile), "# New Target\nUPDATED")
    XCTAssertEqual(try String(contentsOf: firstFile), original)
    try FileManager.default.removeItem(at: privateLink)
    _ = try writeSkill(privateLink)
    let regular = try PluginStorage.readSkillDocument(id: "user:review", root: root)
    XCTAssertFalse(regular.isLinkedSource, "Reloaded previews must not describe a replaced folder as a link")
  }

  func testPrivateUninstallDeletesOnlyLinkIncludingRegisteredDanglingLink() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let target = base.appendingPathComponent("Shared")
    let file = try writeSkill(target)
    let root = base.appendingPathComponent("Data"), shortcut = root.appendingPathComponent("Skills/review")
    try link(shortcut, target: target)
    let original = try Data(contentsOf: file)
    _ = try PluginStorage.removeStandaloneSkill(id: "user:review", root: root)
    XCTAssertEqual(try Data(contentsOf: file), original)
    XCTAssertFalse(FileManager.default.fileExists(atPath: shortcut.path))
    try link(shortcut, target: target)
    _ = try PluginStorage.setSkillEnabled(false, id: "user:review", root: root)
    try FileManager.default.removeItem(at: target)
    XCTAssertTrue(try PluginStorage.skills(preferences: PluginStorage.load(root: root), root: root,
      includeDisabled: true).isEmpty)
    let removed = try PluginStorage.removeStandaloneSkill(id: "user:review", root: root)
    XCTAssertTrue(removed.disabledSkillIDs.isEmpty)
    XCTAssertTrue(removed.standaloneSkills.isEmpty)
    XCTAssertThrowsError(try FileManager.default.destinationOfSymbolicLink(atPath: shortcut.path))
  }

  func testBrokenCyclicAndFileTargetsDoNotHideHealthySkillsButDocumentLinksRemainInvalid() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.appendingPathComponent("Data"), project = base.appendingPathComponent("Project")
    let healthy = base.appendingPathComponent("Healthy")
    let file = try writeSkill(healthy)
    for folder in [root.appendingPathComponent("Skills"), project.appendingPathComponent(".agents/skills")] {
      try link(folder.appendingPathComponent("review"), target: healthy)
      try link(folder.appendingPathComponent("missing"), target: base.appendingPathComponent("Missing"))
      try link(folder.appendingPathComponent("regular"), target: file)
      try link(folder.appendingPathComponent("cycle"), target: folder.appendingPathComponent("cycle"))
    }
    XCTAssertEqual(try PluginStorage.skills(preferences: PluginPreferences(), root: root).map(\.skillID), ["review"])
    XCTAssertEqual(try PluginStorage.repositorySkills(project: project).map(\.skillID), ["review"])
    let invalid = base.appendingPathComponent("Invalid")
    try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
    try link(invalid.appendingPathComponent("SKILL.md"), target: file)
    try link(root.appendingPathComponent("Skills/invalid"), target: invalid)
    try link(project.appendingPathComponent(".agents/skills/invalid"), target: invalid)
    XCTAssertThrowsError(try PluginStorage.skills(preferences: PluginPreferences(), root: root))
    XCTAssertThrowsError(try PluginStorage.repositorySkills(project: project))
  }

  func testSharedLinkedRepositorySourcesDeduplicateAndDisabledTargetIsConsistent() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let target = base.appendingPathComponent("Shared"), root = base.appendingPathComponent("Data")
    _ = try writeSkill(target)
    let first = base.appendingPathComponent("First"), second = base.appendingPathComponent("Second")
    try link(first.appendingPathComponent(".agents/skills/review"), target: target)
    try link(second.appendingPathComponent(".agents/skills/alias"), target: target)
    let library = PluginStorage.repositorySkillLibrary(projectPaths: [second.path, first.path])
    XCTAssertEqual(library.skills.count, 1)
    XCTAssertTrue(library.issues.isEmpty)
    let skill = try XCTUnwrap(library.skills.first)
    XCTAssertEqual(library.projectPathsBySkillID[skill.id], second.path)
    let preferences = try PluginStorage.setRepositorySkillEnabled(false, id: skill.id, project: second, root: root)
    for project in [first, second] {
      XCTAssertTrue(try PluginStorage.discoveryContext(preferences: preferences, root: root,
        repositoryRoot: project, readTool: true).skills.isEmpty)
    }
  }

  @MainActor func testMonitoringTracksLinkedContentsAndRetargetingRejectsStaleImplicitRead() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let first = base.appendingPathComponent("First"), second = base.appendingPathComponent("Second")
    let file = try writeSkill(first), secondFile = try writeSkill(second)
    let root = base.appendingPathComponent("Data"), project = base.appendingPathComponent("Project")
    let privateLink = root.appendingPathComponent("Skills/review")
    let repositoryLink = project.appendingPathComponent(".agents/skills/alias")
    try link(privateLink, target: first); try link(repositoryLink, target: first)
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true; store.restoringLibrary = false; store.scopeLoaded = true; store.project = project
    await store.loadPlugins(); await store.refreshSkillsIfChanged()
    let advertised = store.composerSkills
    let privateSkill = try XCTUnwrap(advertised.first { $0.isStandalone })
    let fingerprint = SkillSourceSnapshot.fingerprint(root: root, projects: [project.path])
    try Data("# Changed\nUPDATED-INSTRUCTIONS".utf8).write(to: file)
    XCTAssertNotEqual(fingerprint, SkillSourceSnapshot.fingerprint(root: root, projects: [project.path]))
    await store.refreshSkillsIfChanged()
    XCTAssertEqual(Set(store.composerSkills.map(\.title)), ["Changed"])
    let changed = SkillSourceSnapshot.fingerprint(root: root, projects: [project.path])
    try Data(contentsOf: file).write(to: secondFile)
    try FileManager.default.removeItem(at: privateLink); try link(privateLink, target: second)
    XCTAssertNotEqual(changed, SkillSourceSnapshot.fingerprint(root: root, projects: [project.path]))
    let args = String(decoding: try JSONEncoder().encode(["skill_id": privateSkill.id]), as: UTF8.self)
    XCTAssertThrowsError(try store.readImplicitSkill(arguments: args, advertised: advertised, projectPath: project.path))
    await store.refreshSkillsIfChanged()
    let refreshed = store.composerSkills
    XCTAssertTrue(try store.readImplicitSkill(arguments: args, advertised: refreshed,
      projectPath: project.path).text.contains("UPDATED-INSTRUCTIONS"))
    XCTAssertTrue(store.setSkillEnabled(false, id: privateSkill.id))
    XCTAssertFalse(store.composerSkills.contains { $0.isStandalone })
    try FileManager.default.removeItem(at: privateLink)
    await store.refreshSkillsIfChanged()
    XCTAssertTrue(store.pluginsLoaded)
    XCTAssertEqual(store.pluginSettingsCount(.skills), 0)
    XCTAssertTrue(FileManager.default.fileExists(atPath: secondFile.path))
  }

  @MainActor func testLinkedMetadataAndIconsRefreshWithoutReplacingTheLink() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let target = base.appendingPathComponent("Shared")
    _ = try writeSkill(target)
    let root = base.appendingPathComponent("Data"), shortcut = root.appendingPathComponent("Skills/review")
    try link(shortcut, target: target)
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    await store.loadPlugins(); await store.refreshSkillsIfChanged()
    let initial = store.skillSourceFingerprint
    let yaml = target.appendingPathComponent("agents/openai.yaml")
    try FileManager.default.createDirectory(at: yaml.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("interface:\n  display_name: Linked Metadata\n  icon_small: icon.png\n".utf8).write(to: yaml)
    let icon = target.appendingPathComponent("icon.png")
    try Data([1, 2, 3]).write(to: icon)
    await store.refreshSkillsIfChanged()
    XCTAssertNotEqual(store.skillSourceFingerprint, initial)
    XCTAssertEqual(store.installedPluginSkills.first?.title, "Linked Metadata")
    XCTAssertEqual(store.installedPluginSkills.first?.interface.iconSmallURL, icon.resolvingSymlinksInPath())
    let revision = store.repositorySkillRevision, fingerprint = store.skillSourceFingerprint
    try Data([4, 5, 6, 7]).write(to: icon)
    await store.refreshSkillsIfChanged()
    XCTAssertNotEqual(store.skillSourceFingerprint, fingerprint)
    XCTAssertNotEqual(store.repositorySkillRevision, revision)
    XCTAssertTrue(try shortcut.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
  }
}
