import Foundation

extension WorkspaceStore {
  func refreshSkillsIfChanged() async {
    guard libraryLoaded, !shuttingDown, !pluginsLoading, !checkingSkillSources else { return }
    checkingSkillSources = true
    defer { checkingSkillSources = false }
    let root = dataRoot
    let projects = Array(Set(library.projects.map { library.primaryFolder(for: $0) }
      + library.tasks.map(\.project) + [currentProjectKey])).sorted()
    let fingerprint = await Task.detached(priority: .utility) {
      SkillSourceSnapshot.fingerprint(root: root, projects: projects)
    }.value
    guard !shuttingDown, !pluginsLoading, !Task.isCancelled,
      fingerprint != skillSourceFingerprint else { return }
    skillSourceFingerprint = fingerprint
    await loadPlugins()
  }
}
