import Foundation

extension PluginStorage {
  static func standaloneSkillURL(root: URL, id: String) -> URL {
    root.appendingPathComponent("Skills", isDirectory: true).appendingPathComponent(id, isDirectory: true)
  }

  static func createStandaloneSkill(
    id: String, description: String, instructions: String, root: URL
  ) throws -> PluginPreferences {
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
    var preferences = try load(root: root)
    guard !preferences.standaloneSkills.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) else {
      throw AgentFailure(message: "这个独立技能已安装。")
    }
    let directory = root.appendingPathComponent("Skills", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try validateStandaloneDirectory(root: root)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let destination = standaloneSkillURL(root: root, id: id)
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      throw AgentFailure(message: "目标技能目录已存在，未覆盖现有内容。")
    }
    let staging = directory.appendingPathComponent(".create-" + UUID().uuidString, isDirectory: true)
    var moved = false
    do {
      try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
      let file = staging.appendingPathComponent("SKILL.md")
      try Data(document.utf8).write(to: file, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      try FileManager.default.moveItem(at: staging, to: destination)
      moved = true
      preferences.standaloneSkills.append(id)
      preferences.standaloneSkills.sort()
      try save(preferences, root: root)
      return preferences
    } catch {
      try? FileManager.default.removeItem(at: staging)
      if moved { try? FileManager.default.removeItem(at: destination) }
      throw error
    }
  }

  static func updateStandaloneSkill(
    id: String, text: String, expectedOriginal: String, root: URL
  ) throws {
    guard id.hasPrefix("user:") else {
      throw AgentFailure(message: "只能编辑独立技能；插件内技能由插件管理。")
    }
    let skillID = String(id.dropFirst(5))
    try validateID(skillID)
    let preferences = try load(root: root)
    guard preferences.standaloneSkills.contains(skillID) else {
      throw AgentFailure(message: "找不到这个独立技能，请重新加载。")
    }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      text.utf8.count <= 65_536, !text.contains("\0") else {
      throw AgentFailure(message: "技能说明不能为空，且不能超过 64 KiB。")
    }
    try validateStandaloneDirectory(root: root)
    let directory = standaloneSkillURL(root: root, id: skillID)
    let expected = standaloneSkillURL(root: root.resolvingSymlinksInPath(), id: skillID)
    guard directory.resolvingSymlinksInPath().path == expected.path else {
      throw AgentFailure(message: "独立技能目录不能使用符号链接。")
    }
    let file = directory.appendingPathComponent("SKILL.md")
    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      let size = values.fileSize, size <= 65_536 else {
      throw AgentFailure(message: "独立技能文件无效或超过 64 KiB。")
    }
    let current = try Data(contentsOf: file)
    guard current == Data(expectedOriginal.utf8) else {
      throw AgentFailure(message: "技能文件已在外部更改。请重新载入后再编辑。")
    }
    try Data(text.utf8).write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }

  static func installStandaloneSkill(from source: URL, root: URL) throws -> PluginPreferences {
    let source = source.standardizedFileURL
    let id = source.lastPathComponent
    try validateID(id)
    let attributes = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard attributes.isDirectory == true, attributes.isSymbolicLink != true else {
      throw AgentFailure(message: "请选择包含 SKILL.md 的真实技能文件夹。")
    }
    var preferences = try load(root: root)
    guard !preferences.standaloneSkills.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) else {
      throw AgentFailure(message: "这个独立技能已安装。")
    }
    _ = try skillTitle(source.appendingPathComponent("SKILL.md"), fallback: id, sourceName: id)
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
    var traversalError: Error?
    guard let entries = FileManager.default.enumerator(at: source, includingPropertiesForKeys: Array(keys),
      options: [], errorHandler: { _, error in traversalError = error; return false }) else {
      throw AgentFailure(message: "无法读取技能文件夹。")
    }
    var files = 0, bytes = 0
    for case let file as URL in entries {
      let values = try file.resourceValues(forKeys: keys)
      guard values.isSymbolicLink != true, values.isRegularFile == true || values.isDirectory == true else {
        throw AgentFailure(message: "技能不能包含符号链接或特殊文件。")
      }
      if values.isRegularFile == true {
        files += 1
        bytes += values.fileSize ?? 0
      }
      guard files <= maximumFileCount, bytes <= maximumPackageBytes else {
        throw AgentFailure(message: "技能最多包含 2,000 个文件、50 MiB。")
      }
    }
    if let traversalError { throw traversalError }
    let directory = root.appendingPathComponent("Skills", isDirectory: true)
    guard !directory.standardizedFileURL.path.hasPrefix(source.path + "/") else {
      throw AgentFailure(message: "不能把技能复制到自身目录内。")
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try validateStandaloneDirectory(root: root)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let destination = standaloneSkillURL(root: root, id: id)
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      throw AgentFailure(message: "目标技能目录已存在，未覆盖现有内容。")
    }
    let staging = directory.appendingPathComponent(".install-" + UUID().uuidString)
    var moved = false
    do {
      try FileManager.default.copyItem(at: source, to: staging)
      try FileManager.default.moveItem(at: staging, to: destination)
      moved = true
      preferences.standaloneSkills.append(id)
      preferences.standaloneSkills.sort()
      try save(preferences, root: root)
      return preferences
    } catch {
      try? FileManager.default.removeItem(at: staging)
      if moved { try? FileManager.default.removeItem(at: destination) }
      throw error
    }
  }

  static func removeStandaloneSkill(id: String, root: URL) throws -> PluginPreferences {
    var preferences = try load(root: root)
    guard id.hasPrefix("user:"), let index = preferences.standaloneSkills.firstIndex(of: String(id.dropFirst(5))) else {
      throw AgentFailure(message: "只能卸载已安装的独立技能；插件内技能需通过插件管理。")
    }
    try validateStandaloneDirectory(root: root)
    let folder = standaloneSkillURL(root: root, id: preferences.standaloneSkills[index])
    let staging = folder.deletingLastPathComponent().appendingPathComponent(".remove-" + UUID().uuidString)
    let exists = FileManager.default.fileExists(atPath: folder.path)
    if exists { try FileManager.default.moveItem(at: folder, to: staging) }
    preferences.standaloneSkills.remove(at: index)
    preferences.disabledSkillIDs.remove(id)
    do {
      try save(preferences, root: root)
      if exists { try? FileManager.default.removeItem(at: staging) }
      return preferences
    } catch {
      if exists { try? FileManager.default.moveItem(at: staging, to: folder) }
      throw error
    }
  }

  static func standaloneSkillReferences(
    preferences: PluginPreferences, root: URL, includeDisabled: Bool
  ) throws -> [PluginSkillReference] {
    if !preferences.standaloneSkills.isEmpty { try validateStandaloneDirectory(root: root) }
    return try preferences.standaloneSkills.compactMap { id in
      if !includeDisabled && preferences.disabledSkillIDs.contains("user:" + id) { return nil }
      let directory = standaloneSkillURL(root: root, id: id)
      let expected = standaloneSkillURL(root: root.resolvingSymlinksInPath(), id: id)
      guard directory.resolvingSymlinksInPath().path == expected.path else {
        throw AgentFailure(message: "独立技能目录不能使用符号链接。")
      }
      let file = directory.appendingPathComponent("SKILL.md")
      guard FileManager.default.fileExists(atPath: file.path) else { return nil }
      let metadata = try skillMetadata(file, fallback: id, sourceName: id)
      return PluginSkillReference(pluginID: "", pluginName: "本地技能", skillID: id,
        title: metadata.title, fileURL: file, mention: id, summary: metadata.summary,
        isStandalone: true, interface: metadata.interface)
    }
  }

  private static func validateStandaloneDirectory(root: URL) throws {
    let directory = root.appendingPathComponent("Skills", isDirectory: true)
    guard directory.resolvingSymlinksInPath().path == root.resolvingSymlinksInPath()
      .appendingPathComponent("Skills", isDirectory: true).path else {
      throw AgentFailure(message: "独立技能必须保存在 ShipiOS 技能目录内。")
    }
  }
}
