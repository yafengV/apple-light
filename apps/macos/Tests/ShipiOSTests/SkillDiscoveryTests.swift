import XCTest
@testable import ShipiOS

final class SkillDiscoveryTests: XCTestCase {
  private func prepare(_ root: URL) throws -> (URL, PluginSkillReference, PluginPreferences) {
    let project = root.appendingPathComponent("Project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try PluginStorage.createRepositorySkill(id: "review", description: "Review correctness",
      instructions: "FULL-SKILL-INSTRUCTIONS", project: project)
    return (project, try XCTUnwrap(PluginStorage.repositorySkills(project: project).first),
      try PluginStorage.load(root: root.appendingPathComponent("Data")))
  }

  func testCatalogOffersMetadataWithoutLoadingInstructionsAndHonorsPolicy() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (project, skill, preferences) = try prepare(root)
    let data = root.appendingPathComponent("Data")
    let context = try PluginStorage.discoveryContext(preferences: preferences, root: data,
      repositoryRoot: project, readTool: true)
    XCTAssertEqual(context.skills.map(\.id), [skill.id])
    XCTAssertTrue(context.instructions.contains("Review correctness"))
    XCTAssertTrue(context.instructions.contains(skill.fileURL.path))
    XCTAssertFalse(context.instructions.contains("FULL-SKILL-INSTRUCTIONS"))
    XCTAssertTrue(context.instructions.contains(ModelSkillReadTool.name))
    let agents = skill.fileURL.deletingLastPathComponent().appendingPathComponent("agents")
    try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    try Data("policy:\n  allow_implicit_invocation: false\n".utf8)
      .write(to: agents.appendingPathComponent("openai.yaml"))
    let disabled = try PluginStorage.discoveryContext(preferences: preferences, root: data,
      repositoryRoot: project, readTool: false)
    XCTAssertTrue(disabled.skills.isEmpty)
    XCTAssertFalse(disabled.instructions.contains(skill.fileURL.path))
    XCTAssertTrue(try PluginStorage.promptContext(prompt: skill.promptReference, preferences: preferences,
      root: data, repositoryRoot: project).instructions.contains("FULL-SKILL-INSTRUCTIONS"))
  }

  func testDisabledAndOutOfScopeSkillsAreAbsentFromDiscovery() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (project, skill, _) = try prepare(root)
    let data = root.appendingPathComponent("Data")
    let preferences = try PluginStorage.setRepositorySkillEnabled(false, id: skill.id, project: project, root: data)
    XCTAssertTrue(try PluginStorage.discoveryContext(preferences: preferences, root: data,
      repositoryRoot: project, readTool: true).skills.isEmpty)
    XCTAssertTrue(try PluginStorage.discoveryContext(preferences: PluginPreferences(), root: data,
      repositoryRoot: nil, readTool: false).skills.isEmpty)
  }

  func testLargeCatalogKeepsIdentitiesAndBudgetAndWarnsWhenOmittingEntries() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (_, original, _) = try prepare(root)
    let skills = (0..<100).map { index in
      PluginSkillReference(pluginID: "example", pluginName: "Example", skillID: "skill-\(index)",
        title: "Skill \(index)", fileURL: original.fileURL, mention: "example/skill-\(index)",
        summary: String(repeating: "用途说明。", count: 100))
    }
    let context = SkillDiscoveryContext.make(skills: skills, readTool: true)
    XCTAssertLessThanOrEqual(context.instructions.count, 8_000)
    XCTAssertGreaterThan(context.skills.count, 0)
    XCTAssertEqual(context.omittedCount, skills.count - context.skills.count)
    XCTAssertTrue(context.instructions.contains("上下文预算"))
    for skill in context.skills { XCTAssertTrue(context.instructions.contains(skill.id)) }
    XCTAssertLessThanOrEqual(SkillDiscoveryContext.make(skills: skills, readTool: true,
      maxCharacters: 10).instructions.count, 10)
  }

  @MainActor func testReadUsesFreshPolicyAndOnlyAdvertisedTaskScope() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (project, skill, _) = try prepare(root)
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"))
    let arguments = try String(decoding: JSONEncoder().encode(["skill_id": skill.id]), as: UTF8.self)
    let read = try store.readImplicitSkill(arguments: arguments, advertised: [skill], projectPath: project.path)
    XCTAssertTrue(read.text.contains("FULL-SKILL-INSTRUCTIONS"))
    XCTAssertThrowsError(try store.readImplicitSkill(arguments: arguments, advertised: [], projectPath: project.path))
    XCTAssertThrowsError(try store.readImplicitSkill(arguments: arguments, advertised: [skill], projectPath: ""))
    XCTAssertThrowsError(try store.readImplicitSkill(arguments: #"{"skill_id":"/etc/passwd"}"#,
      advertised: [skill], projectPath: project.path))
    _ = try PluginStorage.setRepositorySkillEnabled(false, id: skill.id, project: project, root: store.dataRoot)
    XCTAssertThrowsError(try store.readImplicitSkill(arguments: arguments, advertised: [skill], projectPath: project.path))
    _ = try PluginStorage.setRepositorySkillEnabled(true, id: skill.id, project: project, root: store.dataRoot)
    let agents = skill.fileURL.deletingLastPathComponent().appendingPathComponent("agents")
    try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    try Data("policy:\n  allow_implicit_invocation: false\n".utf8).write(to: agents.appendingPathComponent("openai.yaml"))
    XCTAssertThrowsError(try store.readImplicitSkill(arguments: arguments, advertised: [skill], projectPath: project.path))
    store.pluginsEnabled = false
    XCTAssertThrowsError(try store.readImplicitSkill(arguments: arguments, advertised: [skill], projectPath: project.path))
  }

  func testCodexContinuationIncludesCurrentInstructionsAndOnlyLatestUserMessage() {
    let messages = [ChatMessage(role: "system", content: "CURRENT-CATALOG\nEXPLICIT-INSTRUCTIONS"),
      ChatMessage(role: "user", content: "previous question"),
      ChatMessage(role: "assistant", content: "previous answer"),
      ChatMessage(role: "user", content: "new question")]
    let text = WorkspaceStore.codexContinuationText(messages: messages)
    XCTAssertTrue(text.contains("CURRENT-CATALOG"))
    XCTAssertTrue(text.contains("EXPLICIT-INSTRUCTIONS"))
    XCTAssertTrue(text.hasSuffix("new question"))
    XCTAssertFalse(text.contains("previous question"))
    XCTAssertEqual(WorkspaceStore.codexContinuationText(messages: [.init(role: "user", content: "hello")]), "hello")
  }

  @MainActor func testSkillReaderCountsTowardCombinedToolLimitBeforeAnyRequest() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (_, skill, _) = try prepare(root)
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"))
    let bindings = (0..<128).map { index in
      MCPToolBinding(alias: "tool-\(index)", serverID: UUID(), serverName: "Test",
        connectionToken: UUID(), tool: .init(name: "test", title: "Test", summary: "Test",
          inputSchema: .object(["type": .string("object")])))
    }
    do {
      _ = try await store.streamChatWithTools(runID: "not-created", config: ModelConfiguration(),
        key: nil, messages: [], bindings: bindings, skills: [skill])
      XCTFail("Should reject excess tools before contacting a service")
    } catch { XCTAssertTrue(error.localizedDescription.contains("128")) }
    XCTAssertTrue(store.library.chatRuns.isEmpty)
  }

}
