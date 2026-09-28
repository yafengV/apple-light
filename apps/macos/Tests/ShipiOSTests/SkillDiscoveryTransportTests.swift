import XCTest
@testable import ShipiOS

final class SkillDiscoveryTransportTests: XCTestCase {
  private var server: Process!
  private var endpoint = ""
  override func setUpWithError() throws {
    server = Process()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Fixtures/model_server.py")
    server.arguments = ["-u", fixture.path]
    let pipe = Pipe()
    server.standardOutput = pipe
    server.standardError = FileHandle.nullDevice
    try server.run()
    let port = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard Int(port) != nil else { throw AgentFailure(message: "Local fixture could not start") }
    endpoint = "http://127.0.0.1:\(port)/v1"
  }
  override func tearDown() {
    if server?.isRunning == true { server.terminate(); server.waitUntilExit() }
  }

  @MainActor private func prepare(protocol api: ModelAPIProtocol, root: URL) async throws -> WorkspaceStore {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"),
      agentExecutable: repository.appendingPathComponent("target/debug/shipios-agent"))
    await store.restore()
    let project = root.appendingPathComponent("Project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try PluginStorage.createRepositorySkill(id: "review", description: "Inspect correctness",
      instructions: "TRANSPORT-FULL-INSTRUCTIONS", project: project)
    await store.open(project)
    var config = store.modelConfiguration
    config.baseURL = endpoint
    config.model = api == .codexResponses ? "gpt-5.4" : "fixture"
    config.apiProtocol = api
    try store.saveModelConfiguration(config)
    store.notificationPreferences = .init(timing: .never)
    await store.loadPlugins()
    return store
  }

  @MainActor func testBasicChatDiscoversReadsAndRecordsSkillWithoutExplicitMentionOrMCPConnection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try await prepare(protocol: .chatCompletions, root: root)
    let started = await store.startChat("implicit-skill-read")
    let id = try XCTUnwrap(started, store.error ?? "No chat started")
    await store.modelTask(runID: id)?.value
    let run = try XCTUnwrap(store.library.chatRuns.first { $0.id == id })
    XCTAssertEqual(run.status, "succeeded", run.result?["message"].text ?? "")
    let response = try XCTUnwrap(run.result?["response"].text)
    let body = try JSONDecoder().decode(JSONValue.self, from: Data(response.utf8))
    let system = body["messages"].items.first?["content"].text ?? ""
    XCTAssertTrue(system.contains("Inspect correctness"))
    XCTAssertFalse(system.contains("TRANSPORT-FULL-INSTRUCTIONS"))
    XCTAssertTrue(body["messages"].items.last?["content"].text?.contains("TRANSPORT-FULL-INSTRUCTIONS") == true)
    XCTAssertEqual(run.toolExecutions.map(\.status), [.succeeded])
    XCTAssertEqual(run.result?["invoked_skills"].items.count, 1)
    XCTAssertTrue(store.mcpPendingApprovals.isEmpty)
    XCTAssertTrue(store.mcpServers.isEmpty)
    await store.shutdown()
  }

  @MainActor func testCoreDiscoversRepositorySkillAndReadsActualFileThroughNativeTool() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try await prepare(protocol: .codexResponses, root: root)
    let started = await store.startChat("codex-skill-discovery")
    let id = try XCTUnwrap(started, store.error ?? "No chat started")
    await store.modelTask(runID: id)?.value
    let run = try XCTUnwrap(store.library.chatRuns.first { $0.id == id })
    XCTAssertEqual(run.status, "succeeded", run.result?["message"].text ?? "")
    XCTAssertTrue(run.result?["response"].text?.contains("TRANSPORT-FULL-INSTRUCTIONS") == true)
    XCTAssertTrue(run.toolExecutions.contains { $0.toolName == "命令" && $0.status == .succeeded })
    let owner = try XCTUnwrap(store.library.task(containing: id))
    let skill = try XCTUnwrap(store.composerSkills(for: owner.project).first)
    try Data("---\nname: review\ndescription: UPDATED-DISCOVERY-PURPOSE\n---\nUPDATED-INSTRUCTIONS".utf8)
      .write(to: skill.fileURL)
    await store.loadPlugins()
    let secondStarted = await store.startChat("second discovery request", taskID: owner.id)
    let secondID = try XCTUnwrap(secondStarted, store.error ?? "No follow-up started")
    await store.modelTask(runID: secondID)?.value
    let second = try XCTUnwrap(store.library.chatRuns.first { $0.id == secondID })
    XCTAssertEqual(second.status, "succeeded", second.result?["message"].text ?? "")
    let body = try JSONDecoder().decode(JSONValue.self, from: Data(try XCTUnwrap(second.result?["response"].text).utf8))
    let user = body["input"].items.last { $0["role"].text == "user" }
    let currentText = user?["content"].items.compactMap { $0["text"].text }.joined(separator: "\n") ?? ""
    XCTAssertTrue(currentText.contains("UPDATED-DISCOVERY-PURPOSE"))
    XCTAssertFalse(currentText.contains("UPDATED-INSTRUCTIONS"), "Implicit catalogs carry metadata, not bodies")
    XCTAssertTrue(store.setSkillEnabled(false, skill: skill))
    let thirdStarted = await store.startChat("third discovery request", taskID: owner.id)
    let thirdID = try XCTUnwrap(thirdStarted, store.error ?? "No disabled follow-up started")
    await store.modelTask(runID: thirdID)?.value
    let third = try XCTUnwrap(store.library.chatRuns.first { $0.id == thirdID })
    XCTAssertEqual(third.status, "succeeded", third.result?["message"].text ?? "")
    let disabledBody = try JSONDecoder().decode(JSONValue.self, from: Data(try XCTUnwrap(third.result?["response"].text).utf8))
    let disabledUser = disabledBody["input"].items.last { $0["role"].text == "user" }
    let disabledText = disabledUser?["content"].items.compactMap { $0["text"].text }.joined(separator: "\n") ?? ""
    XCTAssertTrue(disabledText.contains("本轮没有可隐式调用的技能"))
    XCTAssertFalse(disabledText.contains("UPDATED-DISCOVERY-PURPOSE"))
    await store.shutdown()
  }

  @MainActor func testBothProtocolsDiscoverDirectlyAddedPrivateSkillWithoutImport() async throws {
    for api: ModelAPIProtocol in [.chatCompletions, .codexResponses] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let store = try await prepare(protocol: api, root: root)
      try FileManager.default.removeItem(at: root.appendingPathComponent("Project/.agents/skills/review"))
      let file = store.dataRoot.appendingPathComponent("Skills/private-review/SKILL.md")
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("---\nname: Private Review\ndescription: PRIVATE-DISCOVERY-PURPOSE\n---\nPRIVATE-FULL-INSTRUCTIONS".utf8)
        .write(to: file)
      await store.refreshSkillsIfChanged()
      XCTAssertEqual(store.composerSkills.map(\.id), ["user:private-review"])
      XCTAssertEqual(store.pluginSettingsCount(.skills), 1)
      XCTAssertTrue(store.pluginPreferences.standaloneSkills.isEmpty)
      let prompt = api == .chatCompletions ? "implicit-skill-read" : "codex-skill-discovery"
      let started = await store.startChat(prompt)
      let id = try XCTUnwrap(started, store.error ?? "No chat started")
      await store.modelTask(runID: id)?.value
      let run = try XCTUnwrap(store.library.chatRuns.first { $0.id == id })
      XCTAssertEqual(run.status, "succeeded", run.result?["message"].text ?? "")
      let response = try XCTUnwrap(run.result?["response"].text)
      XCTAssertTrue(response.contains("PRIVATE-FULL-INSTRUCTIONS"))
      let body = try JSONDecoder().decode(JSONValue.self, from: Data(response.utf8))
      let initial: String
      if api == .chatCompletions {
        initial = body["messages"].items.first?["content"].text ?? ""
        XCTAssertEqual(run.result?["invoked_skills"].items.compactMap(\.text), ["user:private-review"])
      } else {
        initial = body["input"].items.filter { ["developer", "system", "user"].contains($0["role"].text ?? "") }
          .flatMap { $0["content"].items.compactMap { $0["text"].text } }.joined(separator: "\n")
        XCTAssertTrue(run.toolExecutions.contains { $0.toolName == "命令" && $0.status == .succeeded })
      }
      XCTAssertTrue(initial.contains("PRIVATE-DISCOVERY-PURPOSE"), "Catalog missing for \(api)")
      XCTAssertFalse(initial.contains("PRIVATE-FULL-INSTRUCTIONS"))
      XCTAssertTrue(try PluginStorage.load(root: store.dataRoot).standaloneSkills.isEmpty)
      await store.shutdown()
    }
  }
}
