import XCTest
@testable import ShipiOS

final class SkillMonitoringTests: XCTestCase {
  private func writeSkill(project: URL, title: String) throws -> URL {
    let file = project.appendingPathComponent(".agents/skills/review/SKILL.md")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try Data("# \(title)\nInstructions\n".utf8).write(to: file, options: .atomic)
    return file
  }

  func testSnapshotIsStableAndTracksSkillContentsButIgnoresProjectCode() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let project = base.appendingPathComponent("Project")
    let file = try writeSkill(project: project, title: "First")
    let root = base.appendingPathComponent("Data")
    let first = SkillSourceSnapshot.fingerprint(root: root, projects: [project.path])
    XCTAssertEqual(first, SkillSourceSnapshot.fingerprint(root: root, projects: [project.path]))
    try Data("unrelated source".utf8).write(to: project.appendingPathComponent("app.swift"))
    XCTAssertEqual(first, SkillSourceSnapshot.fingerprint(root: root, projects: [project.path]))
    let originalDate = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
    try Data("# Other\nInstructions\n".utf8).write(to: file)
    try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: file.path)
    XCTAssertNotEqual(first, SkillSourceSnapshot.fingerprint(root: root, projects: [project.path]))
  }

  func testSnapshotFindsNestedPluginSkillChanges() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("Plugins/example/skills/nested/review/SKILL.md")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("# First\n".utf8).write(to: file)
    let first = SkillSourceSnapshot.fingerprint(root: root, projects: [])
    XCTAssertEqual(first, SkillSourceSnapshot.fingerprint(root: root, projects: []))
    try Data("# Updated\n".utf8).write(to: file, options: .atomic)
    XCTAssertNotEqual(first, SkillSourceSnapshot.fingerprint(root: root, projects: []))
  }

  func testSnapshotReadsIconSourcesWithoutDependingOnInterfaceCache() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let project = base.appendingPathComponent("Project")
    let file = try writeSkill(project: project, title: "Review")
    let folder = file.deletingLastPathComponent()
    let yaml = folder.appendingPathComponent("agents/openai.yaml")
    try FileManager.default.createDirectory(at: yaml.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("interface:\n  icon_small: icon.png\n".utf8).write(to: yaml)
    let icon = folder.appendingPathComponent("icon.png")
    try Data([1, 2, 3]).write(to: icon)
    let root = base.appendingPathComponent("Data")
    let first = SkillSourceSnapshot.fingerprint(root: root, projects: [project.path])
    XCTAssertEqual(first, SkillSourceSnapshot.fingerprint(root: root, projects: [project.path]))
    try Data([4, 5, 6, 7]).write(to: icon)
    XCTAssertNotEqual(first, SkillSourceSnapshot.fingerprint(root: root, projects: [project.path]))
  }

  @MainActor func testExternalRepositoryChangesRefreshCandidatesAndPreserveDraft() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let project = base.appendingPathComponent("Project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let store = WorkspaceStore(dataRoot: base.appendingPathComponent("Data"))
    store.libraryLoaded = true
    store.project = project
    store.draft = "Keep my work"
    await store.loadPlugins()
    await store.refreshSkillsIfChanged()
    XCTAssertTrue(store.composerSkills.isEmpty)
    let file = try writeSkill(project: project, title: "First")
    await store.refreshSkillsIfChanged()
    XCTAssertEqual(store.composerSkills.first?.title, "First")
    let before = store.repositorySkillRevision
    _ = try writeSkill(project: project, title: "Updated")
    await store.refreshSkillsIfChanged()
    XCTAssertEqual(store.composerSkills.first?.title, "Updated")
    XCTAssertNotEqual(before, store.repositorySkillRevision)
    XCTAssertEqual(store.draft, "Keep my work")
    try FileManager.default.removeItem(at: file.deletingLastPathComponent())
    await store.refreshSkillsIfChanged()
    XCTAssertTrue(store.composerSkills.isEmpty)
    XCTAssertEqual(store.draft, "Keep my work")
  }

  @MainActor func testDeletedPrivateSkillDisappearsAndReturnsWhenFileIsRestored() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    await store.loadPlugins()
    XCTAssertTrue(store.createStandaloneSkill(id: "review", description: "Review", instructions: "Inspect."))
    await store.refreshSkillsIfChanged()
    let file = try XCTUnwrap(store.installedPluginSkills.first?.fileURL)
    let original = try Data(contentsOf: file)
    try FileManager.default.removeItem(at: file)
    await store.refreshSkillsIfChanged()
    XCTAssertTrue(store.composerSkills.isEmpty)
    XCTAssertTrue(store.pluginsLoaded)
    try original.write(to: file)
    await store.refreshSkillsIfChanged()
    XCTAssertEqual(store.composerSkills.map(\.id), ["user:review"])
  }

  @MainActor func testBrokenInterfaceStopsStaleCandidatesAndAutomaticallyRecovers() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    await store.loadPlugins()
    XCTAssertTrue(store.createStandaloneSkill(id: "review", description: "Review", instructions: "Inspect."))
    await store.refreshSkillsIfChanged()
    let folder = try XCTUnwrap(store.installedPluginSkills.first?.fileURL.deletingLastPathComponent())
    let yaml = folder.appendingPathComponent("agents/openai.yaml")
    try FileManager.default.createDirectory(at: yaml.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("interface: [broken".utf8).write(to: yaml)
    await store.refreshSkillsIfChanged()
    XCTAssertFalse(store.pluginsLoaded)
    XCTAssertTrue(store.composerSkills.isEmpty)
    XCTAssertNotNil(store.pluginsError)
    try Data("interface:\n  display_name: Recovered\n".utf8).write(to: yaml)
    await store.refreshSkillsIfChanged()
    XCTAssertTrue(store.pluginsLoaded)
    XCTAssertEqual(store.composerSkills.first?.title, "Recovered")
    XCTAssertNil(store.pluginsError)
  }

  @MainActor func testAppOwnedPollingRefreshesWithoutWindowAndStopsCleanly() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let project = base.appendingPathComponent("Project")
    _ = try writeSkill(project: project, title: "First")
    let store = WorkspaceStore(dataRoot: base.appendingPathComponent("Data"))
    store.libraryLoaded = true
    store.project = project
    await store.loadPlugins()
    let delegate = AppDelegate()
    delegate.store = store
    delegate.startSkillMonitoring(every: .milliseconds(30))
    defer { delegate.stopSkillMonitoring() }
    for _ in 0..<100 where store.skillSourceFingerprint == nil {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertNotNil(store.skillSourceFingerprint)
    _ = try writeSkill(project: project, title: "Updated")
    for _ in 0..<100 where store.composerSkills.first?.title != "Updated" {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(store.composerSkills.first?.title, "Updated")
    delegate.stopSkillMonitoring()
    let fingerprint = store.skillSourceFingerprint
    _ = try writeSkill(project: project, title: "Stopped")
    try await Task.sleep(for: .milliseconds(120))
    XCTAssertEqual(store.skillSourceFingerprint, fingerprint)
    XCTAssertEqual(store.composerSkills.first?.title, "Updated")
  }
}
