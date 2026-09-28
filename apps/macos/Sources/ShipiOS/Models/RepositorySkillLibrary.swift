import Foundation

struct RepositorySkillLibrary {
  struct Issue: Identifiable {
    let projectPath: String
    let message: String
    var id: String { projectPath }
  }
  var skills: [PluginSkillReference] = []
  var projectPathsBySkillID: [String: String] = [:]
  var issues: [Issue] = []
}

extension PluginStorage {
  static func repositorySkillLibrary(projectPaths: [String]) -> RepositorySkillLibrary {
    var result = RepositorySkillLibrary()
    var seenFiles = Set<String>(), seenProjects = Set<String>()
    // The current project comes first, so shared skills retain that execution scope.
    for path in projectPaths where path.hasPrefix("/") && seenProjects.insert(path).inserted {
      do {
        for skill in try repositorySkills(project: URL(fileURLWithPath: path, isDirectory: true)) {
          guard seenFiles.insert(skill.fileURL.resolvingSymlinksInPath().path).inserted else { continue }
          result.skills.append(skill)
          result.projectPathsBySkillID[skill.id] = path
        }
      } catch { result.issues.append(.init(projectPath: path, message: error.localizedDescription)) }
    }
    result.skills.sort {
      $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        || ($0.title.caseInsensitiveCompare($1.title) == .orderedSame && $0.id < $1.id)
    }
    return result
  }
}

extension WorkspaceStore {
  var skillLibraryProjectPaths: [String] {
    var seen = Set<String>()
    let saved = (library.projects + library.tasks.map(\.project)).sorted()
    return ([currentProjectKey] + saved).filter { $0.hasPrefix("/") && seen.insert($0).inserted }
  }
}
