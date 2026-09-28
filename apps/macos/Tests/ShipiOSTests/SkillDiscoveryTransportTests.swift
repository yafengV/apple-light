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

  @MainActor func testBothProtocolsReadLinkedPrivateAndProjectSkillTargets() async throws {
    for api: ModelAPIProtocol in [.chatCompletions, .codexResponses] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let store = try await prepare(protocol: api, root: root)
      let repositoryFolder = root.appendingPathComponent("Project/.agents/skills/review")
      try FileManager.default.removeItem(at: repositoryFolder)
      let target = root.appendingPathComponent("Shared Skills (external)/review")
      try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
      try Data("---\nname: Linked Review\ndescription: LINKED-TRANSPORT-PURPOSE\n---\nLINKED-TRANSPORT-INSTRUCTIONS".utf8)
        .write(to: target.appendingPathComponent("SKILL.md"))
      try FileManager.default.createSymbolicLink(at: repositoryFolder, withDestinationURL: target)
      let privateFolder = store.dataRoot.appendingPathComponent("Skills/private-review")
      try FileManager.default.createDirectory(at: privateFolder.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(at: privateFolder, withDestinationURL: target)
      await store.refreshSkillsIfChanged()
      XCTAssertEqual(store.composerSkills.count, 2)
      XCTAssertTrue(store.composerSkills.allSatisfy(\.isLinkedSource))
      let started = await store.startChat(api == .chatCompletions ? "implicit-skill-read" : "codex-skill-discovery")
      let id = try XCTUnwrap(started, store.error ?? "No linked skill request")
      await store.modelTask(runID: id)?.value
      let run = try XCTUnwrap(store.library.chatRuns.first { $0.id == id })
      XCTAssertEqual(run.status, "succeeded", run.result?["message"].text ?? "")
      XCTAssertTrue(run.result?["response"].text?.contains("LINKED-TRANSPORT-INSTRUCTIONS") == true)
      if api == .chatCompletions {
        XCTAssertEqual(run.result?["invoked_skills"].items.compactMap(\.text), ["user:private-review"])
      } else {
        XCTAssertTrue(run.toolExecutions.contains { $0.toolName == "命令" && $0.status == .succeeded
          && $0.output?.contains("LINKED-TRANSPORT-INSTRUCTIONS") == true })
      }
      XCTAssertTrue(store.pluginPreferences.standaloneSkills.isEmpty)
      await store.shutdown()
    }
  }

  @MainActor func testBothProtocolsExpandAliasedPathsAndReadLinkedSourceWithoutChangingIdentity() async throws {
    for api: ModelAPIProtocol in [.chatCompletions, .codexResponses] {
      let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: container) }
      let root = container.appendingPathComponent("长目录 \"quoted\"/" + String(repeating: "shared/", count: 8))
      let store = try await prepare(protocol: api, root: root)
      for index in 0..<20 {
        let file = store.dataRoot.appendingPathComponent("Skills/prefix-\(index)/SKILL.md")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("---\nname: Earlier \(index)\ndescription: An earlier purpose\n---\nEarlier instructions.".utf8).write(to: file)
      }
      let folder = root.appendingPathComponent("Project/.agents/skills/review")
      try FileManager.default.removeItem(at: folder)
      let target = container.appendingPathComponent("External 技能 \"quoted\"/review")
      try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
      try Data("---\nname: Zzz Linked Review\ndescription: Inspect linked correctness\n---\nALIASED-LINKED-FULL-INSTRUCTIONS".utf8)
        .write(to: target.appendingPathComponent("SKILL.md"))
      try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: target)
      await store.refreshSkillsIfChanged()
      let advertised = try PluginStorage.discoveryContext(preferences: store.pluginPreferences,
        root: store.dataRoot, repositoryRoot: root.appendingPathComponent("Project"), readTool: api == .chatCompletions)
      XCTAssertFalse(advertised.pathAliases.roots.isEmpty)
      let linked = try XCTUnwrap(advertised.skills.last)
      XCTAssertTrue(linked.isLinkedSource)
      let started = await store.startChat(api == .chatCompletions ? "implicit-skill-read-last" : "codex-skill-discovery")
      let id = try XCTUnwrap(started, store.error ?? "No aliased skill request")
      await store.modelTask(runID: id)?.value
      let run = try XCTUnwrap(store.library.chatRuns.first { $0.id == id })
      XCTAssertEqual(run.status, "succeeded", run.result?["message"].text ?? "")
      let response = try XCTUnwrap(run.result?["response"].text)
      let body = try JSONDecoder().decode(JSONValue.self, from: Data(response.utf8))
      XCTAssertTrue(response.contains("ALIASED-LINKED-FULL-INSTRUCTIONS"), "Protocol \(api): \(run.toolExecutions)")
      let instructions: String
      if api == .chatCompletions {
        instructions = body["messages"].items.first?["content"].text ?? ""
        XCTAssertEqual(run.result?["invoked_skills"].items.compactMap(\.text), [linked.id])
      } else {
        instructions = body["input"].items.filter { ["developer", "system", "user"].contains($0["role"].text ?? "") }
          .flatMap { $0["content"].items.compactMap { $0["text"].text } }.joined(separator: "\n")
        XCTAssertTrue(run.toolExecutions.contains { $0.toolName == "命令" && $0.status == .succeeded
          && $0.output?.contains("ALIASED-LINKED-FULL-INSTRUCTIONS") == true })
      }
      XCTAssertFalse(instructions.contains("ALIASED-LINKED-FULL-INSTRUCTIONS"), "Full instructions must be read on demand")
      var wireRoots: [SkillPathAliases.Root] = []
      var rows: [[String: String]] = []
      for line in instructions.split(separator: "\n") {
        if line.hasPrefix("- {") {
          let root = try JSONDecoder().decode([String: String].self, from: Data(line.dropFirst(2).utf8))
          wireRoots.append(.init(name: try XCTUnwrap(root["alias"]), path: try XCTUnwrap(root["path"])))
        } else if line.hasPrefix("{\"description\":") {
          rows.append(try JSONDecoder().decode([String: String].self, from: Data(line.utf8)))
        }
      }
      let wireAliases = SkillPathAliases(roots: wireRoots)
      XCTAssertFalse(wireRoots.isEmpty)
      XCTAssertEqual(rows.count, advertised.skills.count)
      for (row, skill) in zip(rows, advertised.skills) {
        XCTAssertEqual(row["id"], skill.id)
        XCTAssertTrue(row["path"]?.hasPrefix("r") == true, "Wire path \(row): source root \(skill.catalogRoot?.path ?? "nil"), aliases \(wireRoots)")
        XCTAssertEqual(wireAliases.expand(try XCTUnwrap(row["path"])), skill.fileURL.path)
      }
      XCTAssertEqual(linked.sourceFileURL.path, target.appendingPathComponent("SKILL.md").resolvingSymlinksInPath().path)
      await store.shutdown()
    }
  }

  @MainActor func testCodexSetupFailureAppearsInTimelineAndSurvivesRestore() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try await prepare(protocol: .codexResponses, root: root)
    let started = await store.startChat("codex-startup-failure")
    let id = try XCTUnwrap(started, store.error ?? "No setup failure request")
    await store.modelTask(runID: id)?.value
    let run = try XCTUnwrap(store.library.chatRuns.first { $0.id == id })
    XCTAssertEqual(run.status, "succeeded", run.result?["message"].text ?? "")
    let execution = try XCTUnwrap(run.toolExecutions.first { $0.callID == "fixture-startup-failure" },
      "Missing failed command card: \(run.result?["response"].text ?? "")")
    XCTAssertEqual(execution.status, .failed)
    XCTAssertTrue(execution.output?.contains("directory") == true || execution.output?.contains("Directory") == true,
      execution.output ?? "Missing failure output")
    XCTAssertEqual(run.responseItems?.filter { $0 == .tool(execution.id) }.count, 1)
    let restored = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    let stored = try XCTUnwrap(restored.chatRuns.first { $0.id == id })
    XCTAssertEqual(stored.toolExecutions, run.toolExecutions)
    XCTAssertEqual(stored.responseItems, run.responseItems)
    await store.shutdown()
  }

  @MainActor func testBothProtocolsUseServiceModelWindowAndSwitchBackToCharacterFallback() async throws {
    for api: ModelAPIProtocol in [.chatCompletions, .codexResponses] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let store = try await prepare(protocol: api, root: root)
      for index in 0..<16 {
        let file = store.dataRoot.appendingPathComponent("Skills/prefix-\(index)/SKILL.md")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let description = String(repeating: "Long purpose for earlier skill \(index). ", count: 25)
        try Data("---\nname: Earlier \(index)\ndescription: \(description)\n---\nEarlier instructions.".utf8).write(to: file)
      }
      await store.refreshSkillsIfChanged()
      let base = String(endpoint.dropLast(3))
      var configuration = store.modelConfiguration
      for (path, unit, limit) in [("/model-budget/v1", "approximate_tokens", 8_000),
        ("/v1", "characters", 8_000), ("/small-model-budget/v1", "approximate_tokens", 200)] {
        configuration.baseURL = base + path
        try store.saveModelConfiguration(configuration)
        let prompt = api == .chatCompletions ? "implicit-skill-read-last" : "codex-skill-discovery"
        let started = await store.startChat(prompt)
        let id = try XCTUnwrap(started, store.error ?? "No chat started")
        await store.modelTask(runID: id)?.value
        let run = try XCTUnwrap(store.library.chatRuns.first { $0.id == id })
        XCTAssertEqual(run.status, "succeeded", run.result?["message"].text ?? "")
        XCTAssertEqual(run.result?["skill_catalog_budget"]["unit"], .string(unit))
        XCTAssertEqual(run.result?["skill_catalog_budget"]["limit"], .number(Double(limit)))
        let body = try JSONDecoder().decode(JSONValue.self, from: Data(try XCTUnwrap(run.result?["response"].text).utf8))
        let currentInstructions: String
        if api == .chatCompletions {
          currentInstructions = body["messages"].items.first?["content"].text ?? ""
        } else {
          currentInstructions = body["input"].items.reversed().compactMap { item -> String? in
            guard ["user", "developer"].contains(item["role"].text ?? "") else { return nil }
            let text = item["content"].items.compactMap { $0["text"].text }.joined(separator: "\n")
            return text.contains("以下是当前任务可隐式调用的技能") ? text : nil
          }.first ?? ""
        }
        let rows = currentInstructions.split(separator: "\n").filter { $0.hasPrefix("{\"description\":") }
        XCTAssertEqual(run.result?["skill_catalog_budget"]["included"], .number(Double(rows.count)))
        let budget: SkillMetadataBudget = unit == "characters" ? .characters(limit) : .tokens(limit)
        XCTAssertLessThanOrEqual(rows.reduce(0) { $0 + budget.cost(String($1) + "\n") }, limit)
        if path == "/model-budget/v1" {
          XCTAssertEqual(run.result?["skill_catalog_budget"]["included"], .number(17))
          XCTAssertEqual(run.result?["skill_catalog_budget"]["omitted"], .number(0))
          XCTAssertFalse(run.responseItems?.contains {
            if case .notice(_, .warning, let message) = $0 { return message.contains("上下文预算") }
            return false
          } == true)
        } else if path == "/v1" {
          XCTAssertEqual(run.result?["skill_catalog_budget"]["included"], .number(17))
          XCTAssertTrue(run.result?["response"].text?.contains("TRANSPORT-FULL-INSTRUCTIONS") == true)
        } else {
          XCTAssertNotEqual(run.result?["skill_catalog_budget"]["omitted"], .number(0))
          XCTAssertTrue(run.responseItems?.contains {
            if case .notice(_, .warning, let message) = $0 { return message.contains("未提供给模型") }
            return false
          } == true)
        }
      }
      await store.shutdown()
    }
  }

  @MainActor func testModelMetadataTimeoutFallsBackAndCancelStopsLookupBeforeSending() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try await prepare(protocol: .chatCompletions, root: root)
    var configuration = store.modelConfiguration
    configuration.baseURL = String(endpoint.dropLast(3)) + "/slow-models/v1"
    try store.saveModelConfiguration(configuration)
    let began = Date()
    let started = await store.startChat("implicit-skill-read")
    let id = try XCTUnwrap(started, store.error ?? "No chat started")
    await store.modelTask(runID: id)?.value
    XCTAssertLessThan(Date().timeIntervalSince(began), 5)
    XCTAssertEqual(store.library.chatRuns.first { $0.id == id }?.status, "succeeded")
    XCTAssertEqual(store.library.chatRuns.first { $0.id == id }?.result?["skill_catalog_budget"]["unit"], .string("characters"))
    store.invalidateSkillModelMetadata(account: configuration.credentialAccount)
    let cancelStarted = await store.startChat("implicit-skill-read")
    let cancelID = try XCTUnwrap(cancelStarted)
    try await Task.sleep(for: .milliseconds(100))
    let cancelledAt = Date()
    let owner = try XCTUnwrap(store.library.task(containing: cancelID))
    let job = store.modelTask(runID: cancelID)
    await store.cancel(taskID: owner.id)
    await job?.value
    XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 1)
    XCTAssertEqual(store.library.chatRuns.first { $0.id == cancelID }?.status, "cancelled")
    XCTAssertEqual(store.library.chatRuns.first { $0.id == cancelID }?.result?["response"].text, "")
    XCTAssertNil(store.skillModelCatalogs[ModelCatalogSource(configuration)])
    await store.shutdown()
  }

  @MainActor func testBothProtocolsReadCatalogTailAfterDescriptionCompressionAndPersistBudgetWarning() async throws {
    for api: ModelAPIProtocol in [.chatCompletions, .codexResponses] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let store = try await prepare(protocol: api, root: root)
      for index in 0..<16 {
        let file = store.dataRoot.appendingPathComponent("Skills/prefix-\(index)/SKILL.md")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let description = String(repeating: "Long purpose for earlier skill \(index). ", count: 25)
        try Data("---\nname: Earlier \(index)\ndescription: \(description)\n---\nEarlier instructions.".utf8).write(to: file)
      }
      await store.refreshSkillsIfChanged()
      let catalog = try PluginStorage.discoveryContext(preferences: store.pluginPreferences, root: store.dataRoot,
        repositoryRoot: root.appendingPathComponent("Project"), readTool: api == .chatCompletions)
      XCTAssertEqual(catalog.skills.count, 17)
      XCTAssertEqual(catalog.omittedCount, 0)
      XCTAssertNotNil(catalog.warningMessage)
      let prompt = api == .chatCompletions ? "implicit-skill-read-last" : "codex-skill-discovery"
      let started = await store.startChat(prompt)
      let id = try XCTUnwrap(started, store.error ?? "No chat started")
      await store.modelTask(runID: id)?.value
      let run = try XCTUnwrap(store.library.chatRuns.first { $0.id == id })
      XCTAssertEqual(run.status, "succeeded", run.result?["message"].text ?? "")
      XCTAssertTrue(run.result?["response"].text?.contains("TRANSPORT-FULL-INSTRUCTIONS") == true)
      XCTAssertTrue(run.responseItems?.contains {
        if case .notice(_, .warning, let message) = $0 { return message == catalog.warningMessage }
        return false
      } == true)
      XCTAssertTrue(run.toolExecutions.contains { $0.status == .succeeded
        && $0.output?.contains("TRANSPORT-FULL-INSTRUCTIONS") == true })
      let restored = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
      XCTAssertEqual(restored.chatRuns.first { $0.id == id }?.responseItems, run.responseItems)
      await store.shutdown()
    }
  }

  @MainActor func testBothProtocolsPromptBeforeExplicitSkillRequestAndOfferInstalledMCPTools() async throws {
    let process = Process(), pipe = Pipe()
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Fixtures/mcp_server.py")
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-u", fixture.path, "http"]
    process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
    try process.run()
    defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
    let port = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard Int(port) != nil else { throw AgentFailure(message: "MCP fixture could not start") }
    for api: ModelAPIProtocol in [.chatCompletions, .codexResponses] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let store = try await prepare(protocol: api, root: root)
      let metadata = root.appendingPathComponent("Project/.agents/skills/review/agents/openai.yaml")
      try FileManager.default.createDirectory(at: metadata.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("dependencies:\n  tools:\n    - type: mcp\n      value: fixturedep\n      url: http://127.0.0.1:\(port)/mcp\n".utf8)
        .write(to: metadata)
      await store.refreshSkillsIfChanged()
      let skippedStarted = await store.startChat("$repo/review dependency request")
      let skippedID = try XCTUnwrap(skippedStarted, store.error ?? "No chat started")
      for _ in 0..<200 where store.codexPendingQuestions.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
      let questionID = try XCTUnwrap(store.codexPendingQuestions.keys.first)
      XCTAssertTrue(store.mcpServers.isEmpty)
      XCTAssertEqual(store.library.chatRuns.first { $0.id == skippedID }?.result?["response"].text, "")
      await store.answerCodexQuestion(questionID, answers: ["skill_mcp_dependency_install": ["继续而不安装"]])
      await store.modelTask(runID: skippedID)?.value
      let skipped = try XCTUnwrap(store.library.chatRuns.first { $0.id == skippedID })
      XCTAssertEqual(skipped.status, "succeeded", skipped.result?["message"].text ?? "")
      XCTAssertEqual(skipped.codexQuestions.first?.status, .answered)
      XCTAssertTrue(store.mcpServers.isEmpty)
      let owner = try XCTUnwrap(store.library.task(containing: skippedID))
      let repeatedStarted = await store.startChat("$repo/review another dependency request", taskID: owner.id)
      let repeatedID = try XCTUnwrap(repeatedStarted, store.error ?? "No follow-up started")
      await store.modelTask(runID: repeatedID)?.value
      XCTAssertEqual(store.library.chatRuns.first { $0.id == repeatedID }?.status, "succeeded")
      XCTAssertTrue(store.codexPendingQuestions.isEmpty)
      XCTAssertTrue(store.library.chatRuns.first { $0.id == repeatedID }?.codexQuestions.isEmpty == true)
      store.newTask()
      let installedStarted = await store.startChat("$repo/review skill-dependency-request-echo")
      let installedID = try XCTUnwrap(installedStarted, store.error ?? "No chat started")
      for _ in 0..<200 where store.codexPendingQuestions.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
      let installQuestionID = try XCTUnwrap(store.codexPendingQuestions.keys.first)
      await store.answerCodexQuestion(installQuestionID, answers: ["skill_mcp_dependency_install": ["安装并启用"]])
      await store.modelTask(runID: installedID)?.value
      let installed = try XCTUnwrap(store.library.chatRuns.first { $0.id == installedID })
      XCTAssertEqual(installed.status, "succeeded", installed.result?["message"].text ?? "")
      XCTAssertEqual(try MCPServerStorage.load(root: store.dataRoot).map(\.name), ["fixturedep"])
      let body = try JSONDecoder().decode(JSONValue.self, from: Data(try XCTUnwrap(installed.result?["response"].text).utf8))
      XCTAssertTrue(body["tools"].pretty.contains("fixturedep"), "Newly installed tools must be offered in the same request")
      if api == .chatCompletions {
        let server = try XCTUnwrap(store.mcpServers.first)
        XCTAssertEqual(store.mcpConnectionStates[server.id]?.tools.count, 2)
      }
      XCTAssertTrue(store.codexPendingQuestions.isEmpty)
      XCTAssertTrue(store.codexQuestionContinuations.isEmpty)
      let restored = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
      XCTAssertEqual(restored.chatRuns.first { $0.id == installedID }?.codexQuestions.first?.purpose, "skill_dependencies")
      await store.shutdown()
    }
  }
}
