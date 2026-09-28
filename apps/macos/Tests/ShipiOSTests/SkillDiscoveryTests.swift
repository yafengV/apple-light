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

  func testBudgetShortensDescriptionsBeforeOmittingAnyCompleteSkillIdentity() throws {
    let source = URL(fileURLWithPath: "/tmp/技能目录/example/SKILL.md")
    let skills = (0..<12).map { index in
      PluginSkillReference(pluginID: "example", pluginName: "Example", skillID: "skill-\(index)",
        title: "Skill \(index)", fileURL: source, mention: "example/skill-\(index)",
        summary: String(repeating: "Long purpose \"quoted\"\n😀é / ", count: 50))
    }
    let context = SkillDiscoveryContext.make(skills: skills, readTool: true)
    XCTAssertEqual(context.skills.map(\.id), skills.map(\.id))
    XCTAssertEqual(context.omittedCount, 0)
    XCTAssertEqual(context.shortenedDescriptionCount, skills.count)
    XCTAssertTrue(context.warningMessage?.contains("全部技能") == true)
    XCTAssertLessThanOrEqual(context.instructions.count, 8_000)
    let rows = try context.instructions.split(separator: "\n").filter { $0.hasPrefix("{") }.map {
      try JSONDecoder().decode([String: String].self, from: Data($0.utf8))
    }
    XCTAssertEqual(rows.compactMap { $0["id"] }, skills.map(\.id))
    for (skill, row) in zip(skills, rows) {
      XCTAssertEqual(row["path"], source.path)
      XCTAssertTrue(skill.summary.hasPrefix(try XCTUnwrap(row["description"])))
      XCTAssertFalse(row["description"]?.isEmpty == true)
    }
    let lengths = rows.compactMap { $0["description"]?.count }
    XCTAssertLessThanOrEqual((lengths.max() ?? 0) - (lengths.min() ?? 0), 1)
  }

  func testMinimumBudgetKeepsWholeJSONAndZeroBudgetNeverLeaksFragments() throws {
    let source = URL(fileURLWithPath: "/tmp/quoted \"来源\"/SKILL.md")
    let empty = (0..<4).map { index in
      PluginSkillReference(pluginID: "example", pluginName: "Example", skillID: "skill-\(index)",
        title: "Skill \(index)", fileURL: source, mention: "example/skill-\(index)", summary: "")
    }
    let minimum = SkillDiscoveryContext.make(skills: empty, readTool: false).instructions.count
    let described = empty.map { skill in
      PluginSkillReference(pluginID: skill.pluginID, pluginName: skill.pluginName, skillID: skill.skillID,
        title: skill.title, fileURL: source, mention: skill.mention, summary: String(repeating: "用途", count: 600))
    }
    let exact = SkillDiscoveryContext.make(skills: described, readTool: false, maxCharacters: minimum)
    XCTAssertEqual(exact.skills.map(\.id), described.map(\.id))
    XCTAssertEqual(exact.omittedCount, 0)
    XCTAssertEqual(exact.instructions.count, minimum)
    XCTAssertEqual(exact.instructions.split(separator: "\n").filter { $0.hasPrefix("{") }.count, 4)
    for limit in [-1, 0, 10, minimum - 1] {
      let reduced = SkillDiscoveryContext.make(skills: described, readTool: false, maxCharacters: limit)
      XCTAssertLessThanOrEqual(reduced.instructions.count, max(0, limit))
      for line in reduced.instructions.split(separator: "\n") where line.hasPrefix("{") {
        let row = try JSONDecoder().decode([String: String].self, from: Data(line.utf8))
        XCTAssertEqual(row["path"], source.path)
        XCTAssertEqual(row["description"], "")
      }
    }
    XCTAssertEqual(SkillDiscoveryContext.make(skills: [], readTool: true, maxCharacters: 0).instructions, "")
  }

  @MainActor func testAdvertisedSkillRemainsReadableAfterOtherSkillsFillTheDefaultCatalog() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (project, skill, _) = try prepare(root)
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"))
    for index in 0..<70 {
      let file = store.dataRoot.appendingPathComponent("Skills/prefix-\(index)/SKILL.md")
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("---\nname: Earlier \(index)\ndescription: Earlier purpose\n---\nInstructions.".utf8).write(to: file)
    }
    let fresh = try PluginStorage.discoveryContext(preferences: .init(), root: store.dataRoot,
      repositoryRoot: project, readTool: true)
    XCTAssertGreaterThan(fresh.omittedCount, 0)
    XCTAssertFalse(fresh.skills.contains { $0.id == skill.id })
    let arguments = try String(decoding: JSONEncoder().encode(["skill_id": skill.id]), as: UTF8.self)
    let read = try store.readImplicitSkill(arguments: arguments, advertised: [skill], projectPath: project.path)
    XCTAssertTrue(read.text.contains("FULL-SKILL-INSTRUCTIONS"))
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
