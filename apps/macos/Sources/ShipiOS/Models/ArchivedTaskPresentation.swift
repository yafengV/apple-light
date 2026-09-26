import Foundation

enum ArchivedTaskSort: String, CaseIterable, Identifiable {
  case updated, created, alphabetical
  var id: Self { self }
  var title: String {
    switch self { case .updated: "更新时间"; case .created: "创建时间"; case .alphabetical: "名称" }
  }
}
enum ArchivedTaskKind: String, CaseIterable, Identifiable {
  case all, local, cloud
  var id: Self { self }
  var title: String {
    switch self { case .all: "全部任务"; case .local: "本地"; case .cloud: "云端" }
  }
}
enum ArchivedProjectFilter: Hashable {
  case all, project(String), projectless, automations
}
struct ArchivedTaskEntry: Identifiable {
  let task: WorkspaceTask
  let displayProject: String
  let projectTitle: String
  let createdAt: Date?
  let updatedAt: Date?
  let isAutomation: Bool
  var id: String { task.id }
}
struct ArchivedTaskGroup: Identifiable {
  let id: String
  let title: String
  let project: String?
  var entries: [ArchivedTaskEntry]
}
struct ArchivedTaskPresentation {
  let entries: [ArchivedTaskEntry]
  private let knownProjects: [String: String]
  init(library: WorkspaceLibrary, runs: [AgentRun] = [], automationTaskIDs: Set<String> = []) {
    knownProjects = Dictionary(library.projects.filter { path in
      !path.isEmpty && !library.managedWorktrees.contains(where: { $0.path == path })
    }.map { ($0, library.projectTitle($0)) },
      uniquingKeysWith: { first, _ in first })
    let byID = Dictionary((library.localRuns + runs).map { ($0.id, $0) },
      uniquingKeysWith: { first, last in first.updatedAt > last.updatedAt ? first : last })
    entries = library.tasks.filter { $0.archived && !$0.isPopoutDraft }.map { original in
      var task = original
      task.title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
      for id in task.runIDs { if let run = byID[id] { task.includeDates(from: run) } }
      let displayProject = library.sidebarProject(for: task)
      return ArchivedTaskEntry(task: task, displayProject: displayProject,
        projectTitle: library.projectTitle(displayProject),
        createdAt: task.createdAt ?? task.updatedAt, updatedAt: task.updatedAt ?? task.createdAt,
        isAutomation: automationTaskIDs.contains(task.id)
          || task.runIDs.contains { byID[$0]?.request["automation_id"].text != nil })
    }
  }
  var projects: [(path: String, title: String)] {
    var values = knownProjects
    for entry in entries where !entry.displayProject.isEmpty {
      values[entry.displayProject] = entry.projectTitle
    }
    return values.map { (path: $0.key, title: $0.value) }.sorted {
      let order = $0.title.localizedCompare($1.title)
      return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
    }
  }
  func effectiveFilter(_ filter: ArchivedProjectFilter) -> ArchivedProjectFilter {
    if case .project(let path) = filter, !projects.contains(where: { $0.path == path }) { return .all }
    return filter
  }
  func groups(query: String, project: ArchivedProjectFilter, kind: ArchivedTaskKind,
    sort: ArchivedTaskSort) -> [ArchivedTaskGroup] {
    // All current ShipiOS execution is local, including requests to an independent model API.
    guard kind != .cloud else { return [] }
    let project = effectiveFilter(project)
    let search = ArchivedTaskSearch(query)
    let matches = entries.filter { entry in
      let include: Bool
      switch project {
      case .all: include = true
      case .project(let path): include = entry.displayProject == path && !entry.isAutomation
      case .projectless: include = entry.task.project.isEmpty && !entry.isAutomation
      case .automations: include = entry.isAutomation
      }
      // Codex indexes the displayed label and cwd basename as separate fields,
      // not a concatenation or the parent directories of the project path.
      let basename = entry.displayProject.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
      return include && search.matches([entry.task.title,
        entry.task.project.isEmpty ? "" : entry.projectTitle,
        basename.split(whereSeparator: \.isWhitespace).prefix(3).joined(separator: " ")])
    }
    guard !matches.isEmpty else { return [] }
    if project != .all {
      return [.init(id: "filtered", title: "", project: nil, entries: matches.sorted { precedes($0, $1, sort) })]
    }
    var groups = Dictionary(grouping: matches, by: { $0.displayProject }).map { path, entries in
      ArchivedTaskGroup(id: "project:" + path, title: path.isEmpty ? "无项目" : entries[0].projectTitle,
        project: path.isEmpty ? nil : path, entries: entries.sorted { precedes($0, $1, sort) })
    }
    groups.sort {
      if sort != .alphabetical {
        let a = $0.entries.compactMap { date($0, sort) }.max() ?? .distantPast
        let b = $1.entries.compactMap { date($0, sort) }.max() ?? .distantPast
        if a != b { return a > b }
      }
      let order = ($0.project == nil ? "" : $0.title).localizedCompare($1.project == nil ? "" : $1.title)
      return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
    }
    return groups
  }
  private func date(_ entry: ArchivedTaskEntry, _ sort: ArchivedTaskSort) -> Date? {
    sort == .created ? entry.createdAt : entry.updatedAt
  }
  private func precedes(_ a: ArchivedTaskEntry, _ b: ArchivedTaskEntry, _ sort: ArchivedTaskSort) -> Bool {
    let order = a.task.title.localizedCompare(b.task.title)
    if sort == .alphabetical, order != .orderedSame { return order == .orderedAscending }
    let ad = date(a, sort) ?? .distantPast, bd = date(b, sort) ?? .distantPast
    if ad != bd { return ad > bd }
    return order == .orderedSame ? a.id < b.id : order == .orderedAscending
  }
}
