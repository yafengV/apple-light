import Foundation

struct SidebarGroup: Codable, Identifiable, Equatable {
  var id = UUID().uuidString
  var name: String
  var collapsed = false
}

struct SidebarLayout: Codable, Equatable {
  var groups: [SidebarGroup] = []
  var placement: [String: String] = [:]
  var order: [String: [String]] = [:]
  static let pinned = "pinned"
  static let projects = "projects"
  static let projectless = project("")
  static func project(_ path: String) -> String { "project:" + path }
}

enum SidebarItem: Hashable, Identifiable {
  case project(String)
  case task(String)
  case contentTab(String)
  var id: String {
    switch self {
    case .project(let path): return "p:" + path
    case .task(let id): return "t:" + id
    case .contentTab(let id): return "c:" + id
    }
  }
  var dragToken: String { "shipios-sidebar-v1:" + id }
  init?(dragToken: String) {
    let prefix = "shipios-sidebar-v1:"
    guard dragToken.hasPrefix(prefix) else { return nil }
    let value = String(dragToken.dropFirst(prefix.count))
    if value.hasPrefix("p:") {
      self = .project(String(value.dropFirst(2)))
    } else if value.hasPrefix("t:") {
      self = .task(String(value.dropFirst(2)))
    } else if value.hasPrefix("c:") {
      self = .contentTab(String(value.dropFirst(2)))
    } else {
      return nil
    }
  }
}

extension WorkspaceLibrary {
  /// Mirrors the rendered section order; collapsed children, archives, popouts,
  /// and pinned content tabs do not occupy numbered chat positions.
  var visibleSidebarTasks: [WorkspaceTask] {
    let sections = [SidebarLayout.pinned] + sidebar.groups.filter { !$0.collapsed }.map(\.id)
      + [SidebarLayout.projects, SidebarLayout.projectless]
    var seen = Set<String>()
    let tasksByID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return sections.flatMap { section in
      sidebarItems(in: section).flatMap { item -> [SidebarItem] in
        if case .project(let path) = item {
          return collapsedProjects.contains(path) ? [] : sidebarItems(in: SidebarLayout.project(path))
        }
        return [item]
      }
    }.compactMap { item in
      guard case .task(let id) = item, seen.insert(id).inserted else { return nil }
      return tasksByID[id]
    }
  }

  func sidebarSection(for item: SidebarItem) -> String {
    if let group = sidebar.placement[item.id], sidebar.groups.contains(where: { $0.id == group }) {
      return group
    }
    switch item {
    case .project(let path):
      return pinnedProjects.contains(path) ? SidebarLayout.pinned : SidebarLayout.projects
    case .task(let id):
      guard let task = tasks.first(where: { $0.id == id }) else { return "" }
      return task.pinned ? SidebarLayout.pinned : SidebarLayout.project(task.project)
    case .contentTab(let id):
      return pinnedContentTabs.contains(where: { $0.id == id }) ? SidebarLayout.pinned : ""
    }
  }

  func sidebarItems(in section: String) -> [SidebarItem] {
    let candidates =
      projects.map(SidebarItem.project)
      + tasks.filter { !$0.archived && !$0.isPopoutDraft }.map { SidebarItem.task($0.id) }
      + pinnedContentTabs.map { SidebarItem.contentTab($0.id) }
    let visible = candidates.filter { sidebarSection(for: $0) == section }
    let saved = sidebar.order[section] ?? []
    let byID = Dictionary(visible.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var used = Set<String>()
    return (saved.compactMap { byID[$0] } + visible).filter { used.insert($0.id).inserted }
  }

  @discardableResult mutating func moveSidebarItem(
    _ item: SidebarItem, to section: String, before: SidebarItem? = nil
  ) -> Bool {
    switch item {
    case .project(let path): guard projects.contains(path) else { return false }
    case .task(let id): guard tasks.contains(where: { $0.id == id }) else { return false }
    case .contentTab(let id):
      guard pinnedContentTabs.contains(where: { $0.id == id }) else { return false }
    }
    let isGroup = sidebar.groups.contains { $0.id == section }
    let isPinned = section == SidebarLayout.pinned
    let isDefault: Bool
    switch item {
    case .project: isDefault = section == SidebarLayout.projects
    case .task(let id):
      isDefault =
        tasks.first { $0.id == id }.map { section == SidebarLayout.project($0.project) } ?? false
    case .contentTab: isDefault = false
    }
    if case .contentTab = item {
      guard isPinned else { return false }
    } else {
      guard isGroup || isPinned || isDefault else { return false }
    }
    if let before {
      guard before != item, sidebarItems(in: section).contains(before) else { return false }
    }
    // Materialize the visible order before changing membership, preserving each unaffected row.
    var destination = sidebarItems(in: section).filter { $0 != item }
    if let before, let index = destination.firstIndex(of: before) {
      destination.insert(item, at: index)
    } else {
      destination.append(item)
    }
    for key in Array(sidebar.order.keys) { sidebar.order[key]?.removeAll { $0 == item.id } }
    sidebar.placement[item.id] = isGroup ? section : nil
    switch item {
    case .project(let path):
      if isPinned { pinnedProjects.insert(path) } else { pinnedProjects.remove(path) }
    case .task(let id):
      if let index = tasks.firstIndex(where: { $0.id == id }) { tasks[index].pinned = isPinned }
    case .contentTab: break
    }
    sidebar.order[section] = destination.map(\.id)
    return true
  }

  mutating func deleteSidebarGroup(_ id: String) {
    guard sidebar.groups.contains(where: { $0.id == id }) else { return }
    sidebar.groups.removeAll { $0.id == id }
    sidebar.placement = sidebar.placement.filter { $0.value != id }
    sidebar.order.removeValue(forKey: id)
  }

  @discardableResult mutating func moveSidebarGroup(_ id: String, before target: String?) -> Bool {
    guard let index = sidebar.groups.firstIndex(where: { $0.id == id }), id != target,
      target == nil || sidebar.groups.contains(where: { $0.id == target })
    else { return false }
    let group = sidebar.groups.remove(at: index)
    if let target, let index = sidebar.groups.firstIndex(where: { $0.id == target }) {
      sidebar.groups.insert(group, at: index)
    } else {
      sidebar.groups.append(group)
    }
    return true
  }
}
