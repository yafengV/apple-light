import XCTest

@testable import ShipiOS

final class AgentTests: XCTestCase {
  func testFragmentedUnicodeFramesAndMultipleMessages() throws {
    var decoder = FrameDecoder()
    let source = Data("{\"message\":\"你好\"}\n{\"id\":2}\n".utf8)
    var frames: [JSONValue] = []
    for byte in source { frames += try decoder.append(Data([byte])) }
    XCTAssertEqual(frames.count, 2)
    XCTAssertEqual(frames[0]["message"].text, "你好")
    XCTAssertEqual(frames[1]["id"].int, 2)
    XCTAssertTrue(decoder.buffer.isEmpty)
  }

  func testMalformedAndUnboundedFramesFail() {
    var decoder = FrameDecoder()
    XCTAssertThrowsError(try decoder.append(Data("not json\n".utf8)))
    decoder = FrameDecoder()
    XCTAssertThrowsError(try decoder.append(Data(repeating: 65, count: 16 * 1024 * 1024 + 1)))
  }

  func testRunDecodingKeepsTerminalAndMillisecondTimestamp() throws {
    let run = try JSONDecoder().decode(
      AgentRun.self,
      from: Data(
        """
        {"id":"r1","kind":"build","project":"/tmp/project","status":"cancelled",
         "createdAt":1700000000123,"updatedAt":1700000000456,
         "request":{"kind":"build","scheme":"Demo"},"result":null}
        """.utf8))
    XCTAssertFalse(run.isActive)
    XCTAssertEqual(run.date.timeIntervalSince1970, 1700000000.123, accuracy: 0.001)
    XCTAssertEqual(run.title, "构建 · Demo")
  }

  @MainActor func testRealAgentHandshakeInspectionErrorsAndReconnect() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let binary = repository.appendingPathComponent("target/debug/shipios-agent")
    XCTAssertTrue(
      FileManager.default.isExecutableFile(atPath: binary.path),
      "Build the Rust agent before swift test")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "shipios-swift-test-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("Sample.xcodeproj"), withIntermediateDirectories: true)
    let client = AgentClient()
    do {
      try client.start(
        executable: binary, project: root, dataDirectory: root.appendingPathComponent("data"))
      let hello = try await client.request("initialize", ["protocolVersion": .number(1)])
      XCTAssertEqual(hello["capabilities"]["modelCalls"].boolean, true)
      XCTAssertEqual(hello["capabilities"]["codexResponses"].boolean, true)
      XCTAssertEqual(hello["capabilities"]["codexEventReplay"].boolean, false)
      let inspection = try await client.request("project.inspect").decode(ProjectInspection.self)
      XCTAssertEqual(inspection.containers, ["Sample.xcodeproj"])
      do {
        _ = try await client.request(
          "run.start",
          [
            "kind": .string("build"), "container": .string("../Outside.xcodeproj"),
            "scheme": .string("Demo"),
          ])
        XCTFail("An invalid project must be rejected")
      } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
      let runs = try await client.request("run.list").decode([AgentRun].self)
      XCTAssertTrue(runs.isEmpty)
      await client.stop()
      // Reconnecting to the exact same state directory proves the old process released its lock.
      try client.start(
        executable: binary, project: root, dataDirectory: root.appendingPathComponent("data"))
      _ = try await client.request("initialize", ["protocolVersion": .number(1)])
      await client.stop()
      do {
        _ = try await client.request("run.list")
        XCTFail("Disconnected request must fail")
      } catch { XCTAssertTrue(error.localizedDescription.contains("未连接")) }
    } catch {
      await client.stop()
      throw error
    }
  }

  @MainActor func testSharedCodexEnvironmentLoadsSavesAndRejectsExternalChanges() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let binary = repository.appendingPathComponent("target/debug/shipios-agent")
    XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary.path))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shipios-env-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("project")
    let environment = project.appendingPathComponent(".codex/environments/environment.toml")
    try FileManager.default.createDirectory(
      at: environment.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("""
      version = 1
      name = "Shared"
      [setup]
      script = "echo default"
      [setup.darwin]
      script = "echo mac"
      [[actions]]
      name = "Run"
      icon = "run"
      command = "./run.sh"
      platform = "darwin"
      """.utf8).write(to: environment)
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("data"), agentExecutable: binary)
    await store.open(project)
    XCTAssertTrue(store.connected, store.error ?? "")
    XCTAssertEqual(store.environmentName, "Shared")
    XCTAssertEqual(store.worktreeSetupScript, "echo default")
    XCTAssertEqual(store.setupPlatformScripts.darwin, "echo mac")
    XCTAssertEqual(store.environmentActions.first?.title, "Run")
    store.worktreeCleanupScript = "echo cleanup"
    await store.saveSharedEnvironment()
    XCTAssertTrue(store.environmentStatus.contains("已保存"), store.environmentStatus)
    XCTAssertTrue(try String(contentsOf: environment).contains("echo cleanup"))
    let external = try String(contentsOf: environment) + "\n# external edit\n"
    try external.write(to: environment, atomically: true, encoding: .utf8)
    store.worktreeCleanupScript = "echo changed"
    await store.saveSharedEnvironment()
    XCTAssertTrue(store.environmentStatus.contains("changed outside ShipiOS"), store.environmentStatus)
    XCTAssertEqual(try String(contentsOf: environment), external)
    await store.loadSharedEnvironment()
    XCTAssertEqual(store.worktreeCleanupScript, "echo cleanup")
    let privateProject = root.appendingPathComponent("private-project")
    try FileManager.default.createDirectory(at: privateProject, withIntermediateDirectories: true)
    store.library.profiles[privateProject.path] = BuildProfile(worktreeSetupScript: "echo private")
    await store.open(privateProject)
    XCTAssertTrue(store.connected, store.error ?? "")
    XCTAssertFalse(store.environmentExists)
    XCTAssertEqual(store.worktreeSetupScript, "echo private")
    await store.shutdown()
  }

  @MainActor func testMultipleCodexEnvironmentsCanBeSelectedAndCreated() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let binary = repository.appendingPathComponent("target/debug/shipios-agent")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shipios-envs-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("project")
    let directory = project.appendingPathComponent(".codex/environments")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for (fileName, name, script) in [
      ("environment.toml", "Default", "echo default"),
      ("environment-2.toml", "Second", "echo second"),
    ] {
      try "version = 1\nname = '\(name)'\n[setup]\nscript = '\(script)'\n"
        .write(to: directory.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
    }
    try "[setup\n".write(to: directory.appendingPathComponent("broken.toml"),
      atomically: true, encoding: .utf8)
    let data = root.appendingPathComponent("data")
    let store = WorkspaceStore(dataRoot: data, agentExecutable: binary)
    await store.open(project)
    XCTAssertTrue(store.connected, store.error ?? "")
    XCTAssertEqual(store.environmentFileName, "environment.toml")
    XCTAssertEqual(store.environmentFiles.count, 3)
    XCTAssertEqual(store.environmentFiles.first(where: { $0.fileName == "broken.toml" })?.error,
      "This environment file needs attention")
    await store.selectSharedEnvironment("environment-2.toml")
    XCTAssertEqual(store.environmentName, "Second")
    XCTAssertEqual(store.worktreeSetupScript, "echo second")
    XCTAssertEqual(store.library.profiles[project.path]?.worktreeSetupScript, "echo second")
    store.newTaskEnvironmentSelection = "environment-2.toml"
    let chosen = try await store.managedEnvironmentSnapshot(selectionID: store.newTaskEnvironmentSelection)
    XCTAssertEqual(chosen.fileName, "environment-2.toml")
    XCTAssertEqual(chosen.macOSSetupScript, "echo second")
    let noEnvironment = try await store.managedEnvironmentSnapshot(
      selectionID: WorktreeEnvironmentChoice.none)
    XCTAssertEqual(noEnvironment, ManagedEnvironmentSnapshot.none)
    await store.selectSharedEnvironment("broken.toml")
    XCTAssertTrue(store.environmentStatus.contains("无法解析"), store.environmentStatus)
    XCTAssertNotNil(store.environmentRevision)
    XCTAssertEqual(store.worktreeSetupScript, "")
    store.environmentName = "Repaired"
    await store.saveSharedEnvironment()
    XCTAssertTrue(store.environmentStatus.contains("已保存"), store.environmentStatus)
    XCTAssertTrue(try String(contentsOf: directory.appendingPathComponent("broken.toml"),
      encoding: .utf8).contains("Repaired"))
    store.createSharedEnvironment()
    XCTAssertEqual(store.environmentFileName, "environment-3.toml")
    store.worktreeSetupScript = "echo third"
    store.environmentActions = [EnvironmentAction(title: "Incomplete")]
    await store.saveSharedEnvironment()
    XCTAssertTrue(store.environmentStatus.contains("名称和命令"), store.environmentStatus)
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: directory.appendingPathComponent("environment-3.toml").path))
    store.environmentActions = []
    await store.saveSharedEnvironment()
    XCTAssertTrue(store.environmentStatus.contains("已保存"), store.environmentStatus)
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: directory.appendingPathComponent("environment-3.toml").path))
    await store.shutdown()
    let restored = WorkspaceStore(dataRoot: data, agentExecutable: binary)
    await restored.restore()
    XCTAssertEqual(restored.environmentFileName, "environment-3.toml")
    XCTAssertEqual(restored.worktreeSetupScript, "echo third")
    await restored.shutdown()
  }

  @MainActor func testParentEnvironmentAppearsAndCanBeUsedForNewTask() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let binary = repository.appendingPathComponent("target/debug/shipios-agent")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shipios-inherited-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("repo/app")
    let parent = root.appendingPathComponent("repo")
    let shared = parent.appendingPathComponent(".codex/environments/environment.toml")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: parent.appendingPathComponent(".git"),
      withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: shared.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try "version = 1\nname = 'Parent'\n[setup]\nscript = 'echo parent'\n"
      .write(to: shared, atomically: true, encoding: .utf8)
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("data"), agentExecutable: binary)
    await store.open(project)
    XCTAssertTrue(store.connected, store.error ?? "")
    let inherited = try XCTUnwrap(store.environmentFiles.first(where: { $0.inherited }))
    XCTAssertEqual(inherited.fileName, "environment.toml")
    XCTAssertEqual(inherited.sourceFolder, "repo")
    await store.selectSharedEnvironment(inherited.id)
    XCTAssertEqual(store.environmentName, "Parent")
    store.newTaskEnvironmentSelection = inherited.id
    let snapshot = try await store.managedEnvironmentSnapshot(selectionID: inherited.id)
    XCTAssertEqual(snapshot.macOSSetupScript, "echo parent")
    XCTAssertEqual(snapshot.fileName, inherited.id)
    store.environmentName = "Updated parent"
    await store.saveSharedEnvironment()
    XCTAssertTrue(store.environmentStatus.contains("已保存"), store.environmentStatus)
    XCTAssertTrue(try String(contentsOf: shared, encoding: .utf8).contains("Updated parent"))
    await store.shutdown()
  }

  @MainActor func testEnvironmentCatalogListsOtherProjectsWithoutSwitchingWorkspace() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let binary = repository.appendingPathComponent("target/debug/shipios-agent")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shipios-catalog-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let first = root.appendingPathComponent("first")
    let second = root.appendingPathComponent("second")
    for (project, name) in [(first, "First"), (second, "Second")] {
      let folder = project.appendingPathComponent(".codex/environments")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: project.appendingPathComponent(".git"),
        withIntermediateDirectories: true)
      try "version = 1\nname = '\(name)'\n[setup]\nscript = ''\n"
        .write(to: folder.appendingPathComponent("environment.toml"), atomically: true,
          encoding: .utf8)
    }
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("data"), agentExecutable: binary)
    await store.open(first)
    XCTAssertTrue(store.connected, store.error ?? "")
    store.library.projects.append(second.path)
    let missing = root.appendingPathComponent("missing")
    store.library.projects.append(missing.path)
    await store.refreshEnvironmentCatalog()
    XCTAssertEqual(store.environmentCatalog[first.path]?.first?.name, "First")
    XCTAssertEqual(store.environmentCatalog[second.path]?.first?.name, "Second")
    XCTAssertEqual(store.project?.path, first.path)
    XCTAssertNotNil(store.environmentCatalogErrors[missing.path])
    do {
      _ = try await store.client.request("environment.list", ["projectPath": .string("relative")])
      XCTFail("相对目录不应参与跨项目查询")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("invalid method parameters"))
    }
    await store.shutdown()
  }

  @MainActor func testEnvironmentEditorChangesOtherProjectWithoutSwitchingActiveTask() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let binary = repository.appendingPathComponent("target/debug/shipios-agent")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shipios-editor-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let active = root.appendingPathComponent("active")
    let other = root.appendingPathComponent("other")
    for (project, name) in [(active, "Active"), (other, "Other")] {
      let directory = project.appendingPathComponent(".codex/environments")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: project.appendingPathComponent(".git"),
        withIntermediateDirectories: true)
      try "version = 1\nname = '\(name)'\n[setup]\nscript = ''\n"
        .write(to: directory.appendingPathComponent("environment.toml"), atomically: true,
          encoding: .utf8)
    }
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("data"), agentExecutable: binary)
    await store.open(active)
    XCTAssertTrue(store.connected, store.error ?? "")
    let task = WorkspaceTask(id: "active-task", project: active.path,
      title: "Keep selected", runIDs: [])
    store.library.tasks.append(task)
    store.selection = task.id
    store.draft = "Keep this draft"
    let originalSelection = store.selection
    let editor = EnvironmentSettingsSession()
    await editor.open(other.path, title: "Other", executable: binary)
    XCTAssertTrue(editor.connected, editor.status)
    XCTAssertEqual(editor.name, "Other")
    XCTAssertFalse(editor.canSave)
    editor.name = "  "
    XCTAssertFalse(editor.canSave)
    editor.name = "Edited other"
    editor.actions = [EnvironmentAction(title: "Incomplete")]
    XCTAssertFalse(editor.canSave)
    editor.actions = []
    XCTAssertTrue(editor.canSave)
    let saved = await editor.save()
    XCTAssertTrue(saved, editor.status)
    XCTAssertFalse(editor.canSave)
    let otherFile = other.appendingPathComponent(".codex/environments/environment.toml")
    let externallyEdited = try String(contentsOf: otherFile, encoding: .utf8) + "\n# outside edit\n"
    try externallyEdited.write(to: otherFile, atomically: true, encoding: .utf8)
    editor.name = "Draft after external edit"
    let conflictSave = await editor.save()
    XCTAssertFalse(conflictSave)
    XCTAssertTrue(editor.saveConflict)
    XCTAssertFalse(editor.canSave)
    XCTAssertEqual(editor.name, "Draft after external edit")
    XCTAssertEqual(try String(contentsOf: otherFile, encoding: .utf8), externallyEdited)
    let repeatedSave = await editor.save()
    XCTAssertFalse(repeatedSave)
    await editor.refresh()
    XCTAssertFalse(editor.saveConflict)
    XCTAssertFalse(editor.hasUnsavedChanges)
    XCTAssertFalse(editor.canSave)
    XCTAssertEqual(editor.name, "Edited other")
    editor.name = "Unsaved draft"
    XCTAssertTrue(editor.hasUnsavedChanges)
    await editor.load()
    XCTAssertEqual(editor.name, "Edited other")
    XCTAssertFalse(editor.hasUnsavedChanges)
    XCTAssertEqual(store.project?.path, active.path)
    XCTAssertEqual(store.selection, originalSelection)
    XCTAssertEqual(store.draft, "Keep this draft")
    XCTAssertEqual(store.environmentName, "Active")
    XCTAssertTrue(try String(contentsOf: other.appendingPathComponent(
      ".codex/environments/environment.toml"), encoding: .utf8).contains("Edited other"))
    XCTAssertFalse(try String(contentsOf: active.appendingPathComponent(
      ".codex/environments/environment.toml"), encoding: .utf8).contains("Edited other"))
    try "[invalid TOML".write(to: otherFile, atomically: true, encoding: .utf8)
    await editor.refresh()
    XCTAssertTrue(editor.parseError)
    XCTAssertTrue(editor.canSave)
    editor.name = "Repaired"
    let repaired = await editor.save()
    XCTAssertTrue(repaired, editor.status)
    XCTAssertFalse(editor.parseError)
    XCTAssertFalse(editor.canSave)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: otherFile.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: otherFile.path)
    }
    await editor.load()
    XCTAssertTrue(editor.readError, editor.status)
    XCTAssertFalse(editor.canSave)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: otherFile.path)
    await editor.load()
    XCTAssertFalse(editor.readError, editor.status)
    XCTAssertFalse(editor.canSave)
    editor.create()
    let newOtherEnvironment = editor.fileName
    editor.name = "New other environment"
    let otherSaved = await editor.save()
    XCTAssertTrue(otherSaved, editor.status)
    let otherSelected = await store.environmentSettingsDidSave(projectPath: other.path,
      fileName: newOtherEnvironment, created: true)
    XCTAssertTrue(otherSelected)
    XCTAssertEqual(store.library.profiles[other.path]?.environmentFileName, newOtherEnvironment)
    XCTAssertEqual(store.library.newTaskEnvironmentSelections[other.path], newOtherEnvironment)
    XCTAssertEqual(store.project?.path, active.path)
    XCTAssertEqual(store.selection, originalSelection)
    XCTAssertEqual(store.draft, "Keep this draft")
    await editor.open(active.path, title: "Active", executable: binary)
    XCTAssertTrue(editor.connected, editor.status)
    editor.create()
    let newActiveEnvironment = editor.fileName
    editor.name = "New active environment"
    let activeSaved = await editor.save()
    XCTAssertTrue(activeSaved, editor.status)
    let activeSelected = await store.environmentSettingsDidSave(projectPath: active.path,
      fileName: newActiveEnvironment, created: true)
    XCTAssertTrue(activeSelected)
    XCTAssertEqual(store.environmentFileName, newActiveEnvironment)
    XCTAssertEqual(store.newTaskEnvironmentSelection, newActiveEnvironment)
    XCTAssertEqual(store.selection, originalSelection)
    XCTAssertEqual(store.draft, "Keep this draft")
    await editor.close()
    await store.shutdown()
  }
}
