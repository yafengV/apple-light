import Foundation

struct SkillDocument {
  let text: String
  let fileURL: URL
  let isLinkedSource: Bool
  let toolDependencies: [SkillToolDependency]
  let reference: PluginSkillReference
}

extension PluginStorage {
  // Only callers that already validated a local discovery root may follow a skill folder.
  // Individual document links remain invalid; resources stay within the resolved folder.
  static func localSkillFile(in folder: URL, expectedFileURL: URL? = nil) throws -> URL {
    let target = folder.resolvingSymlinksInPath().standardizedFileURL
    guard try target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
      throw AgentFailure(message: "技能链接目标不是可用的文件夹。")
    }
    let file = target.appendingPathComponent("SKILL.md")
    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      let size = values.fileSize, size <= 65_536,
      file.resolvingSymlinksInPath().path == file.path else {
      throw AgentFailure(message: "技能文件必须是目标文件夹内的普通文件，且不能超过 64 KiB。")
    }
    if let expectedFileURL, expectedFileURL.standardizedFileURL != file.standardizedFileURL {
      throw AgentFailure(message: "技能链接目标已更改。请重新载入后再继续。")
    }
    return file
  }
}
