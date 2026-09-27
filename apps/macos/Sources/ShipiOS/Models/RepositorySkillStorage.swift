import Foundation

extension PluginStorage {
  static func repositorySkills(project: URL) throws -> [PluginSkillReference] {
    let project = project.standardizedFileURL
    guard FileManager.default.fileExists(atPath: project.path) else { return [] }
    let rootValues = try project.resourceValues(forKeys: [.isDirectoryKey])
    guard rootValues.isDirectory == true else {
      throw AgentFailure(message: "项目目录不可用，无法读取项目技能。")
    }
    let agents = project.appendingPathComponent(".agents", isDirectory: true)
    guard FileManager.default.fileExists(atPath: agents.path) else { return [] }
    let skills = agents.appendingPathComponent("skills", isDirectory: true)
    guard FileManager.default.fileExists(atPath: skills.path) else { return [] }
    let canonical = project.resolvingSymlinksInPath()
    guard agents.resolvingSymlinksInPath().path == canonical.appendingPathComponent(".agents").path,
      skills.resolvingSymlinksInPath().path == canonical.appendingPathComponent(".agents/skills").path,
      try skills.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
      throw AgentFailure(message: "项目技能目录必须位于项目内，不能使用符号链接。")
    }
    let folders = try FileManager.default.contentsOfDirectory(
      at: skills, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles])
    var found: [PluginSkillReference] = []
    for folder in folders {
      let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true else { continue }
      guard values.isSymbolicLink != true,
        folder.resolvingSymlinksInPath().path == canonical
          .appendingPathComponent(".agents/skills/\(folder.lastPathComponent)").path else {
        throw AgentFailure(message: "项目技能目录不能使用符号链接。")
      }
      let id = folder.lastPathComponent
      try validateID(id)
      let file = folder.appendingPathComponent("SKILL.md")
      guard FileManager.default.fileExists(atPath: file.path) else { continue }
      let metadata = try skillMetadata(file, fallback: id, sourceName: id)
      found.append(PluginSkillReference(
        pluginID: "", pluginName: "项目技能", skillID: id,
        title: metadata.title, fileURL: file, mention: "repo/" + id,
        summary: metadata.summary, repositoryRoot: project))
    }
    return found.sorted {
      $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        || ($0.title.caseInsensitiveCompare($1.title) == .orderedSame && $0.id < $1.id)
    }
  }
}
