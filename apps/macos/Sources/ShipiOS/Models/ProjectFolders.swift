import Foundation

struct ProjectEditRequest: Identifiable {
  let id = UUID()
  let project: String
  let title: String
  let folders: [String]
  var primary: String? = nil
  var primaryPath: String { primary ?? project }
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
  func projectOwner(for path: String) -> String {
    projectScopeOwners[path] ?? path
  }

  func primaryFolder(for project: String) -> String {
    let owner = projectOwner(for: project)
    return projectPrimaryFolders[owner] ?? owner
  }

  func configuredFolders(for project: String) -> [String] {
    let owner = projectOwner(for: project)
    guard !owner.isEmpty else { return [] }
    return [primaryFolder(for: owner)] + (projectAdditionalFolders[owner] ?? [])
  }

  func isKnownProjectScope(_ path: String) -> Bool {
    projects.contains(projectOwner(for: path))
  }

  var projectScopePaths: [String] {
    Array(Set(projects + projectScopeOwners.keys.filter { projects.contains(projectScopeOwners[$0] ?? "") }))
  }

  func additionalFolders(for project: String) -> [String] {
    guard !project.isEmpty else { return [] }
    if projectAdditionalFolders[project] != nil {
      return configuredFolders(for: project).filter { $0 != project }
    }
    // A worktree replaces the primary checkout while keeping the attached folders.
    if let source = managedWorktrees.first(where: { $0.path == project })?.source
      ?? permanentWorktrees.first(where: { $0.path == project })?.source,
      source != project {
      return configuredFolders(for: source).filter { $0 != source && $0 != project }
    }
    return configuredFolders(for: project).filter { $0 != project }
  }

  func folderPaths(for project: String) -> [String] {
    project.isEmpty ? [] : [project] + additionalFolders(for: project)
  }
}
