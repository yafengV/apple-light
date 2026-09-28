import Foundation

struct ProjectEditRequest: Identifiable {
  let id = UUID()
  let project: String
  let title: String
  let folders: [String]
}

enum ProjectFolders {
  /// Validate at save and again at turn submission; a saved folder may disappear later.
  static func canonical(_ paths: [String]) throws -> [String] {
    var seen = Set<String>()
    return try paths.compactMap { path in
      guard path.hasPrefix("/"), !path.contains("\0") else {
        throw AgentFailure(message: "请选择有效的本地文件夹。")
      }
      let url = URL(fileURLWithPath: path, isDirectory: true)
        .resolvingSymlinksInPath().standardizedFileURL
      var directory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory),
        directory.boolValue, FileManager.default.isReadableFile(atPath: url.path) else {
        throw AgentFailure(message: "文件夹不可用：\(path)")
      }
      return seen.insert(url.path).inserted ? url.path : nil
    }
  }
}

extension WorkspaceLibrary {
  func additionalFolders(for project: String) -> [String] {
    guard !project.isEmpty else { return [] }
    if let saved = projectAdditionalFolders[project] { return saved }
    // A worktree replaces the primary checkout while keeping the attached folders.
    if let source = managedWorktrees.first(where: { $0.path == project })?.source
      ?? permanentWorktrees.first(where: { $0.path == project })?.source,
      source != project {
      return projectAdditionalFolders[source] ?? []
    }
    return []
  }

  func folderPaths(for project: String) -> [String] {
    project.isEmpty ? [] : [project] + additionalFolders(for: project)
  }
}
