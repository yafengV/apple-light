import XCTest
@testable import ShipiOS

final class SkillDependencyTests: XCTestCase {
  private let yaml = """
    dependencies:
      tools:
        - type: mcp
          value: docs
          description: Look up official docs
          url: https://example.com/mcp
    """

  @MainActor private func prepare(_ root: URL, automation: Bool = false) async throws -> (WorkspaceStore, PluginSkillReference, String) {
    _ = try PluginStorage.createStandaloneSkill(id: "review", description: "Review", instructions: "Inspect.", root: root)
    let file = root.appendingPathComponent("Skills/review/agents/openai.yaml")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(yaml.utf8).write(to: file)
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    await store.loadPlugins(); await store.loadMCPServers()
    let runID = UUID().uuidString
    var request: [String: JSONValue] = ["kind": .string("chat")]
    if automation { request["automation_id"] = .string(UUID().uuidString) }
    let run = AgentRun(id: runID, kind: "chat", project: "", status: "running", createdAt: 1, updatedAt: 1,
      request: .object(request), result: .object(["response": .string("")]))
    store.library.attach(run, to: nil, note: "$review")
    store.library.chatRuns.append(run)
    return (store, try XCTUnwrap(store.composerSkills.first), runID)
  }

  @MainActor private func question(_ store: WorkspaceStore) async throws -> UUID {
    for _ in 0..<100 {
      if let id = store.codexPendingQuestions.keys.first { return id }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw AgentFailure(message: "Dependency question did not appear")
  }

  func testMetadataReadsToolsTransportCommandAndOAuthWithoutChangingInstructions() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try PluginStorage.createStandaloneSkill(id: "review", description: "Review", instructions: "Inspect.", root: root)
    let agents = root.appendingPathComponent("Skills/review/agents")
    try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    try Data((yaml + """

        - type: MCP
          value: local
          transport: stdio
          command: /usr/bin/true
        - type: mcp
          value: oauth-docs
          url: https://example.com/auth
          oauth:
            callbackPort: 9876
        - type: future
          value: other
    """).utf8).write(to: agents.appendingPathComponent("openai.yaml"))
    let document = try PluginStorage.readSkillDocument(id: "user:review", root: root)
    XCTAssertTrue(document.text.contains("Inspect."))
    XCTAssertEqual(document.toolDependencies.map(\.value), ["docs", "local", "oauth-docs", "other"])
    XCTAssertEqual(try document.toolDependencies[0].serverConfiguration().transport, .streamableHTTP)
    XCTAssertEqual(try document.toolDependencies[1].serverConfiguration().command, "/usr/bin/true")
    XCTAssertEqual(document.toolDependencies[2].oauth?.callbackPort, 9876)
    XCTAssertThrowsError(try document.toolDependencies[2].serverConfiguration())
    XCTAssertThrowsError(try document.toolDependencies[3].serverConfiguration())
    XCTAssertEqual(document.reference.interface.toolDependencies, document.toolDependencies)
    try Data("dependencies:\n  tools: [invalid]\n".utf8).write(to: agents.appendingPathComponent("openai.yaml"))
    XCTAssertThrowsError(try PluginStorage.readSkill(id: "user:review", root: root))
  }

  func testDependencyIdentityUsesEndpointOrCommandRatherThanServerNameAndReportsConflicts() throws {
    let dependency = SkillToolDependency(type: "mcp", value: "docs", url: "https://example.com/mcp")
    var existing = try dependency.serverConfiguration()
    existing.name = "alias"; existing.enabled = false
    if case .configured(let found) = dependency.resolve(in: [existing]) { XCTAssertEqual(found.id, existing.id) }
    else { XCTFail("Endpoint alias should be reused, including disabled servers") }
    existing.name = "docs"; existing.url = "https://different.example/mcp"
    if case .unavailable = dependency.resolve(in: [existing]) {} else { XCTFail("Name collision must not overwrite a server") }
    let oauth = SkillToolDependency(type: "mcp", value: "docs", url: "https://example.com/mcp", oauth: .init(callbackPort: 9876))
    existing.url = "https://example.com/mcp"
    if case .configured = oauth.resolve(in: [existing]) {} else { XCTFail("An existing authenticated endpoint is already configured") }
    if case .unavailable = oauth.resolve(in: []) {} else { XCTFail("OAuth is not yet an installable transport flow") }
    for bad in [SkillToolDependency(type: "mcp", value: "docs", url: "file:///tmp/server"),
      .init(type: "mcp", value: "docs", transport: "unknown"),
      .init(type: "mcp", value: "docs", transport: "stdio", command: "bad\ncommand")] {
      XCTAssertThrowsError(try bad.serverConfiguration())
    }
  }

  @MainActor func testSkipRecordsAnswerAndDoesNotPromptAgainForTaskOrWriteConfiguration() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, skill, runID) = try await prepare(root)
    let pending = Task { try await store.prepareSkillDependencies([skill], runID: runID, connect: false) }
    let id = try await question(store)
    XCTAssertTrue(store.mcpServers.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("mcp-servers.json").path))
    XCTAssertEqual(store.codexPendingQuestions[id]?.request.purpose, "skill_dependencies")
    await store.answerCodexQuestion(id, answers: ["skill_mcp_dependency_install": ["继续而不安装"]])
    try await pending.value
    XCTAssertTrue(store.codexPendingQuestions.isEmpty)
    XCTAssertTrue(store.codexQuestionContinuations.isEmpty)
    XCTAssertEqual(store.library.chatRuns.first?.codexQuestions.first?.status, .answered)
    try await store.prepareSkillDependencies([skill], runID: runID, connect: false)
    XCTAssertEqual(store.library.chatRuns.first?.codexQuestions.count, 1)
    XCTAssertTrue(try MCPServerStorage.load(root: root).isEmpty)
  }

  @MainActor func testInstallChoicePersistsOnlyIndependentServersAndReusesExistingAliases() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, skill, runID) = try await prepare(root)
    let pending = Task { try await store.prepareSkillDependencies([skill], runID: runID, connect: false) }
    let id = try await question(store)
    await store.answerCodexQuestion(id, answers: ["skill_mcp_dependency_install": ["安装并启用"]])
    try await pending.value
    let saved = try MCPServerStorage.load(root: root)
    XCTAssertEqual(saved.count, 1)
    XCTAssertEqual(saved.first?.name, "docs")
    XCTAssertTrue(saved.first?.enabled == true)
    XCTAssertEqual(store.library.chatRuns.first?.codexQuestions.first?.status, .answered)
    XCTAssertTrue(store.mcpConnections.isEmpty, "Core connects from the saved configuration itself")
    var alias = saved[0]; alias.name = "already-configured"
    try MCPServerStorage.save([alias], root: root)
    let candidate = SkillDependencyCandidate(skill: skill, dependency: skill.interface.toolDependencies[0], server: saved[0])
    XCTAssertTrue(try store.installSkillDependencies([candidate], projectPath: "").isEmpty)
    XCTAssertEqual(store.mcpServers.map(\.name), ["already-configured"])
    XCTAssertEqual(try MCPServerStorage.load(root: root), [alias])
  }

  @MainActor func testCancellationAndUnattendedRunNeverInstallOrLeaveQuestionsWaiting() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, skill, runID) = try await prepare(root)
    let pending = Task { try await store.prepareSkillDependencies([skill], runID: runID, connect: false) }
    _ = try await question(store)
    pending.cancel()
    do { try await pending.value; XCTFail("Cancelled preparation should stop") } catch is CancellationError {} catch { XCTFail("\(error)") }
    for _ in 0..<100 where !store.codexPendingQuestions.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(store.codexPendingQuestions.isEmpty)
    XCTAssertTrue(store.codexQuestionContinuations.isEmpty)
    XCTAssertTrue(try MCPServerStorage.load(root: root).isEmpty)
    let (scheduled, scheduledSkill, scheduledID) = try await prepare(root.appendingPathComponent("Scheduled"), automation: true)
    try await scheduled.prepareSkillDependencies([scheduledSkill], runID: scheduledID, connect: true)
    XCTAssertTrue(scheduled.codexPendingQuestions.isEmpty)
    XCTAssertTrue(scheduled.mcpServers.isEmpty)
    XCTAssertTrue(scheduled.promptedSkillDependencies.isEmpty)
  }

  @MainActor func testInstallationRechecksDeclarationsAndNameConflictsWithoutPartialWrites() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, skill, _) = try await prepare(root)
    let dependency = skill.interface.toolDependencies[0]
    let candidate = SkillDependencyCandidate(skill: skill, dependency: dependency, server: try dependency.serverConfiguration())
    var conflicting = candidate.server; conflicting.url = "https://different.example/mcp"
    try MCPServerStorage.save([conflicting], root: root)
    XCTAssertThrowsError(try store.installSkillDependencies([candidate], projectPath: ""))
    XCTAssertEqual(try MCPServerStorage.load(root: root), [conflicting])
    try MCPServerStorage.save([], root: root)
    try Data("dependencies:\n  tools: []\n".utf8).write(to: root.appendingPathComponent("Skills/review/agents/openai.yaml"))
    XCTAssertThrowsError(try store.installSkillDependencies([candidate], projectPath: ""))
    XCTAssertTrue(try MCPServerStorage.load(root: root).isEmpty)
  }

  @MainActor func testDependencyEditorUsesMainWindowNavigationPreservesDraftAndDoesNotSaveUntilUserActs() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, skill, _) = try await prepare(root)
    store.draft = "keep my draft"
    store.showSkills()
    XCTAssertTrue(store.configureSkillDependency(skill.interface.toolDependencies[0], skill: skill))
    XCTAssertEqual(store.destination, .settings)
    XCTAssertEqual(store.activePluginSettingsSection, .mcpServers)
    XCTAssertEqual(store.mcpServerEditor?.url, "https://example.com/mcp")
    XCTAssertTrue(try MCPServerStorage.load(root: root).isEmpty)
    store.mcpServerEditor = nil
    store.closeSettings()
    XCTAssertEqual(store.destination, .skills)
    XCTAssertEqual(store.draft, "keep my draft")
  }

  @MainActor func testDeclarationChangesWhileQuestionIsVisiblePreventInstallation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, skill, runID) = try await prepare(root)
    let pending = Task { try await store.prepareSkillDependencies([skill], runID: runID, connect: false) }
    let id = try await question(store)
    try Data(yaml.replacingOccurrences(of: "https://example.com/mcp", with: "https://changed.example/mcp").utf8)
      .write(to: root.appendingPathComponent("Skills/review/agents/openai.yaml"))
    await store.answerCodexQuestion(id, answers: ["skill_mcp_dependency_install": ["安装并启用"]])
    do { try await pending.value; XCTFail("Changed declaration must not install the new or previous endpoint") }
    catch { XCTAssertTrue(error.localizedDescription.contains("技能依赖已更改")) }
    XCTAssertTrue(try MCPServerStorage.load(root: root).isEmpty)
    XCTAssertTrue(store.mcpServers.isEmpty)
    XCTAssertTrue(store.codexPendingQuestions.isEmpty)
    XCTAssertTrue(store.codexQuestionContinuations.isEmpty)
  }

  @MainActor func testConflictingDependencyBatchDoesNotPartiallyInstallAndDisabledAliasStaysDisabled() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, _, _) = try await prepare(root)
    try Data((yaml + """

        - type: mcp
          value: docs
          url: https://other.example/mcp
    """).utf8).write(to: root.appendingPathComponent("Skills/review/agents/openai.yaml"))
    await store.loadPlugins()
    let skill = try XCTUnwrap(store.composerSkills.first)
    let candidates = try skill.interface.toolDependencies.map {
      SkillDependencyCandidate(skill: skill, dependency: $0, server: try $0.serverConfiguration())
    }
    XCTAssertThrowsError(try store.installSkillDependencies(candidates, projectPath: ""))
    XCTAssertTrue(try MCPServerStorage.load(root: root).isEmpty)
    var disabled = candidates[0].server
    disabled.name = "manual-alias"; disabled.enabled = false
    try MCPServerStorage.save([disabled], root: root)
    XCTAssertTrue(try store.installSkillDependencies([candidates[0]], projectPath: "").isEmpty)
    XCTAssertEqual(store.mcpServers, [disabled])
    XCTAssertEqual(try MCPServerStorage.load(root: root), [disabled])
  }
}
