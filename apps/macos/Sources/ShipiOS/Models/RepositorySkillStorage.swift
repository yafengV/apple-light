import Foundation

extension PluginStorage {
  static func setRepositorySkillEnabled(
    _ enabled: Bool, id: String, project: URL, root: URL
  ) throws -> PluginPreferences {
    guard let skill = try repositorySkills(project: project).first(where: { $0.id == id }) else {
      throw AgentFailure(message: "项目技能已移除或项目已切换，请重新加载技能。")
    }
    var preferences = try load(root: root)
    let path = skill.fileURL.resolvingSymlinksInPath().path
    if enabled { preferences.disabledRepositorySkillPaths.remove(path) }
    else { preferences.disabledRepositorySkillPaths.insert(path) }
    try save(preferences, root: root)
    return preferences
  }

  private static func repositorySkillDirectory(project: URL, create: Bool) throws -> URL {
    let project = project.standardizedFileURL
    guard try project.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
      throw AgentFailure(message: "项目目录不可用，无法保存项目技能。")
    }
    let canonical = project.resolvingSymlinksInPath()
    let agents = project.appendingPathComponent(".agents", isDirectory: true)
    let skills = agents.appendingPathComponent("skills", isDirectory: true)
    let manager = FileManager.default
    guard agents.resolvingSymlinksInPath().path == canonical.appendingPathComponent(".agents").path else {
      throw AgentFailure(message: "项目技能目录不能使用符号链接。")
    }
    if create && !manager.fileExists(atPath: agents.path) {
      try manager.createDirectory(at: agents, withIntermediateDirectories: false)
    }
    guard try agents.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
      skills.resolvingSymlinksInPath().path == canonical.appendingPathComponent(".agents/skills").path else {
      throw AgentFailure(message: "项目技能目录不能使用符号链接。")
    }
    if create && !manager.fileExists(atPath: skills.path) {
      try manager.createDirectory(at: skills, withIntermediateDirectories: false)
    }
    guard try skills.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
      throw AgentFailure(message: "项目技能目录不可用。")
    }
    return skills
  }

  static func createRepositorySkill(
    id: String, description: String, instructions: String, project: URL
  ) throws {
    try validateID(id)
    let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
    let instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !description.isEmpty, description.utf8.count <= 1_000,
      !description.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) || $0.value < 32 }),
      !instructions.isEmpty else {
      throw AgentFailure(message: "请填写单行用途描述和技能指令。")
    }
    let quotedDescription = String(decoding: try JSONEncoder().encode(description), as: UTF8.self)
    let document = "---\nname: \(id)\ndescription: \(quotedDescription)\n---\n\n\(instructions)\n"
    guard document.utf8.count <= 65_536 else {
      throw AgentFailure(message: "技能说明不能超过 64 KiB。")
    }
    let directory = try repositorySkillDirectory(project: project, create: true)
    let existing = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    guard !existing.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) else {
      throw AgentFailure(message: "当前项目中已有同名技能，未覆盖现有内容。")
    }
    let destination = directory.appendingPathComponent(id, isDirectory: true)
    let staging = directory.appendingPathComponent(".create-" + UUID().uuidString, isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
      try Data(document.utf8).write(to: staging.appendingPathComponent("SKILL.md"), options: .atomic)
      try FileManager.default.moveItem(at: staging, to: destination)
    } catch {
      try? FileManager.default.removeItem(at: staging)
      throw error
    }
  }

  static func updateRepositorySkill(
    id: String, text: String, expectedOriginal: String, project: URL, expectedFileURL: URL? = nil
  ) throws {
    guard id == "repo:" + project.standardizedFileURL.path + "/" + projectSkillID(from: id) else {
      throw AgentFailure(message: "只能编辑项目技能。")
    }
    let skillID = projectSkillID(from: id)
    try validateID(skillID)
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      text.utf8.count <= 65_536, !text.contains("\0") else {
      throw AgentFailure(message: "技能说明不能为空，且不能超过 64 KiB。")
    }
    let directory = try repositorySkillDirectory(project: project, create: false)
    let folder = directory.appendingPathComponent(skillID, isDirectory: true)
    let file = try localSkillFile(in: folder, expectedFileURL: expectedFileURL)
    guard try Data(contentsOf: file) == Data(expectedOriginal.utf8) else {
      throw AgentFailure(message: "技能文件已在外部更改。请重新载入后再编辑。")
    }
    try Data(text.utf8).write(to: file, options: .atomic)
  }

  private static func projectSkillID(from id: String) -> String {
    String(id.split(separator: "/", omittingEmptySubsequences: false).last ?? "")
  }

  static func repositorySkillScopes(project: URL) -> [URL] {
    let project = project.standardizedFileURL
    var scopes = [project]
    var cursor = project
    var root: URL?
    while true {
      if FileManager.default.fileExists(atPath: cursor.appendingPathComponent(".git").path) {
        root = cursor
        break
      }
      if cursor.path == "/" { break }
      let parent = cursor.deletingLastPathComponent()
      if parent.path == cursor.path { break }
      cursor = parent
    }
    guard let root else { return scopes }
    cursor = project
    while cursor.path != root.path {
      cursor = cursor.deletingLastPathComponent()
      scopes.append(cursor)
    }
    return scopes
  }

  static func repositorySkills(project: URL) throws -> [PluginSkillReference] {
    let project = project.standardizedFileURL
    guard FileManager.default.fileExists(atPath: project.path) else { return [] }
    let rootValues = try project.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey])
    guard rootValues.isDirectory == true else {
      throw AgentFailure(message: "项目目录不可用，无法读取项目技能。")
    }
    return try repositorySkillScopes(project: project).flatMap { try repositorySkills(in: $0) }
  }

  private static func repositorySkills(in scope: URL) throws -> [PluginSkillReference] {
    let agents = scope.appendingPathComponent(".agents", isDirectory: true)
    guard FileManager.default.fileExists(atPath: agents.path) else { return [] }
    let skills = agents.appendingPathComponent("skills", isDirectory: true)
    guard FileManager.default.fileExists(atPath: skills.path) else { return [] }
    let canonical = scope.resolvingSymlinksInPath()
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
      guard values.isDirectory == true || values.isSymbolicLink == true,
        (try? folder.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
      let id = folder.lastPathComponent
      try validateID(id)
      let file = folder.appendingPathComponent("SKILL.md")
      guard FileManager.default.fileExists(atPath: file.path) else { continue }
      let resolved = try localSkillFile(in: folder)
      let metadata = try skillMetadata(resolved, fallback: id, sourceName: id)
      found.append(PluginSkillReference(
        pluginID: "", pluginName: "项目技能 · \(scope.lastPathComponent)", skillID: id,
        title: metadata.title, fileURL: file, mention: "repo/" + id,
        summary: metadata.summary, repositoryRoot: scope, interface: metadata.interface, resolvedFileURL: resolved))
    }
    return found.sorted {
      $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        || ($0.title.caseInsensitiveCompare($1.title) == .orderedSame && $0.id < $1.id)
    }
  }
}
