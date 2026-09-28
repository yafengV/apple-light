import Foundation

extension PluginStorage {
  static func standaloneSkillIDs(preferences: PluginPreferences, root: URL) throws -> [String] {
    let directory = root.appendingPathComponent("Skills", isDirectory: true)
    if !preferences.standaloneSkills.isEmpty || FileManager.default.fileExists(atPath: directory.path) {
      try validateStandaloneDirectory(root: root)
    }
    var found: [String: String] = [:]
    // Include registered folders and preserve disabled preferences across source changes.
    // Actual directory spelling wins when a case-only rename refers to the same file.
    for id in preferences.standaloneSkills {
      if FileManager.default.fileExists(atPath: standaloneSkillURL(root: root, id: id)
        .appendingPathComponent("SKILL.md").path) { found[id.lowercased()] = id }
    }
    guard FileManager.default.fileExists(atPath: directory.path) else { return found.values.sorted() }
    let folders = try FileManager.default.contentsOfDirectory(at: directory,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    for folder in folders {
      let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true || values.isSymbolicLink == true,
        (try? folder.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("SKILL.md").path) else { continue }
      let id = folder.lastPathComponent
      try validateID(id)
      if let previous = found[id.lowercased()], previous != id {
        let other = standaloneSkillURL(root: root, id: previous)
        let first = try FileManager.default.attributesOfItem(atPath: other.path)
        let second = try FileManager.default.attributesOfItem(atPath: folder.path)
        guard let firstDevice = first[.systemNumber] as? NSNumber,
          let secondDevice = second[.systemNumber] as? NSNumber,
          let firstInode = first[.systemFileNumber] as? NSNumber,
          let secondInode = second[.systemFileNumber] as? NSNumber,
          firstDevice == secondDevice, firstInode == secondInode else {
          throw AgentFailure(message: "独立技能目录包含仅大小写不同的重复标识。")
        }
        found[id.lowercased()] = id
        continue
      }
      found[id.lowercased()] = id
    }
    return found.values.sorted()
  }

  static func registerStandaloneSkill(_ id: String, preferences: inout PluginPreferences) {
    let equivalent = preferences.standaloneSkills.filter { $0.caseInsensitiveCompare(id) == .orderedSame }
    let disabled = equivalent.contains { preferences.disabledSkillIDs.contains("user:" + $0) }
    for old in equivalent { preferences.disabledSkillIDs.remove("user:" + old) }
    preferences.standaloneSkills.removeAll { $0.caseInsensitiveCompare(id) == .orderedSame }
    preferences.standaloneSkills.append(id)
    preferences.standaloneSkills.sort()
    if disabled { preferences.disabledSkillIDs.insert("user:" + id) }
  }
}
