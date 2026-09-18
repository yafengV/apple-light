import Foundation

struct SidebarGroupEditor: Identifiable {
  let id = UUID()
  var existingID: String?
  var item: SidebarItem?
}

extension WorkspaceStore {
  func editSidebarGroup(_ group: SidebarGroup? = nil, moving item: SidebarItem? = nil) {
    sidebarGroupDraft = group?.name ?? ""
    sidebarGroupEditor = SidebarGroupEditor(existingID: group?.id, item: item)
  }

  func saveSidebarGroup(_ editor: SidebarGroupEditor) {
    guard sidebarGroupEditor?.id == editor.id else { return }
    let name = sidebarGroupDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    if let id = editor.existingID {
      guard let index = library.sidebar.groups.firstIndex(where: { $0.id == id }) else { return }
      library.sidebar.groups[index].name = String(name.prefix(80))
    } else {
      let group = SidebarGroup(name: String(name.prefix(80)))
      library.sidebar.groups.append(group)
      if let item = editor.item { library.moveSidebarItem(item, to: group.id) }
    }
    saveLibrary()
    sidebarGroupEditor = nil
  }

  func toggleSidebarGroup(_ id: String) {
    guard let index = library.sidebar.groups.firstIndex(where: { $0.id == id }) else { return }
    library.sidebar.groups[index].collapsed.toggle()
    saveLibrary()
  }

  func deleteSidebarGroup(_ id: String) {
    library.deleteSidebarGroup(id)
    sidebarGroupToDelete = nil
    saveLibrary()
  }

  @discardableResult func moveSidebarItem(
    _ item: SidebarItem, to section: String, before: SidebarItem? = nil
  ) -> Bool {
    guard library.moveSidebarItem(item, to: section, before: before) else { return false }
    saveLibrary()
    return true
  }

  func canShiftSidebarItem(_ item: SidebarItem, by offset: Int) -> Bool {
    let items = library.sidebarItems(in: library.sidebarSection(for: item))
    guard let index = items.firstIndex(of: item) else { return false }
    return items.indices.contains(index + offset)
  }

  func shiftSidebarItem(_ item: SidebarItem, by offset: Int) {
    let section = library.sidebarSection(for: item)
    let items = library.sidebarItems(in: section)
    guard let index = items.firstIndex(of: item), items.indices.contains(index + offset) else {
      return
    }
    let target = offset < 0 ? index + offset : index + offset + 1
    moveSidebarItem(item, to: section, before: items.indices.contains(target) ? items[target] : nil)
  }

  func shiftSidebarGroup(_ id: String, by offset: Int) {
    guard let index = library.sidebar.groups.firstIndex(where: { $0.id == id }),
      library.sidebar.groups.indices.contains(index + offset)
    else { return }
    library.sidebar.groups.swapAt(index, index + offset)
    saveLibrary()
  }

  @discardableResult func acceptSidebarDrop(
    _ tokens: [String], to section: String, before item: SidebarItem? = nil
  ) -> Bool {
    guard tokens.count == 1, let token = tokens.first else { return false }
    if let value = SidebarItem(dragToken: token) {
      return moveSidebarItem(value, to: section, before: item)
    }
    let prefix = "shipios-group-v1:"
    guard item == nil, token.hasPrefix(prefix) else { return false }
    let target = section == SidebarLayout.projects ? nil : section
    guard library.moveSidebarGroup(String(token.dropFirst(prefix.count)), before: target) else {
      return false
    }
    saveLibrary()
    return true
  }

  @discardableResult func acceptSidebarItemDrop(_ tokens: [String], on target: SidebarItem) -> Bool
  {
    guard tokens.count == 1, let token = tokens.first, let item = SidebarItem(dragToken: token)
    else { return false }
    if case .project(let path) = target, case .task(let id) = item {
      guard library.tasks.first(where: { $0.id == id })?.project == path else { return false }
      guard library.moveSidebarItem(item, to: SidebarLayout.project(path)) else { return false }
      library.collapsedProjects.remove(path)
      saveLibrary()
      return true
    }
    return moveSidebarItem(item, to: library.sidebarSection(for: target), before: target)
  }
}
