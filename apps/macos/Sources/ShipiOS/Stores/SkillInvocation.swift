import Foundation

extension WorkspaceStore {
  func readImplicitSkill(
    arguments: String, advertised: [PluginSkillReference], projectPath: String
  ) throws -> (skill: PluginSkillReference, text: String) {
    guard pluginsEnabled else { throw AgentFailure(message: "技能已关闭。") }
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(arguments.utf8))
    guard case .object(let fields) = value, fields.count == 1,
      let id = fields["skill_id"]?.text,
      let offered = advertised.first(where: { $0.id == id }) else {
      throw AgentFailure(message: "只能读取本轮技能目录中提供的技能。")
    }
    let preferences = try PluginStorage.load(root: dataRoot)
    let repository = projectPath.isEmpty ? nil : URL(fileURLWithPath: projectPath, isDirectory: true)
    let current = try PluginStorage.implicitSkills(preferences: preferences, root: dataRoot,
      repositoryRoot: repository)
    guard let skill = current.first(where: {
      $0.id == id && $0.sourceFileURL == offered.sourceFileURL
    }) else { throw AgentFailure(message: "技能已停用、移除或不再允许隐式调用。") }
    return (skill, try PluginStorage.readSkill(id: id, root: dataRoot, repositoryRoot: repository,
      expectedFileURL: offered.sourceFileURL))
  }

  func executeSkillRead(
    _ call: ModelFunctionCall, advertised: [PluginSkillReference], runID: String
  ) throws -> String {
    try Task.checkCancellation()
    guard let run = library.chatRuns.first(where: { $0.id == runID }),
      library.task(containing: runID) != nil else { throw CancellationError() }
    var execution = MCPToolExecution(callID: call.id, serverID: ModelSkillReadTool.serverID,
      serverName: "技能", toolName: "读取技能", arguments: call.arguments, status: .running)
    do {
      try saveToolExecution(execution, runID: runID)
      let loaded = try readImplicitSkill(arguments: call.arguments, advertised: advertised,
        projectPath: run.project)
      execution.status = .succeeded
      execution.output = loaded.text
      try saveToolExecution(execution, runID: runID)
      let current = library.chatRuns.first(where: { $0.id == runID })?
        .result?["invoked_skills"].items.compactMap(\.text) ?? []
      if !current.contains(loaded.skill.id) {
        try setChatResultField("invoked_skills",
          value: .array((current + [loaded.skill.id]).map(JSONValue.string)), runID: runID)
      }
      return "技能 \(loaded.skill.title)（\(loaded.skill.fileURL.path)）的完整指令：\n\(loaded.text)"
    } catch {
      execution.status = error is CancellationError ? .cancelled : .failed
      execution.output = error.localizedDescription
      try? saveToolExecution(execution, runID: runID)
      if error is CancellationError { throw error }
      return "Skill error: " + error.localizedDescription
    }
  }
}
