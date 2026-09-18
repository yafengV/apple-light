import SwiftUI

struct ArchivedTasksSettingsView: View {
  let store: WorkspaceStore
  private enum DeletionFocus: Hashable { case all, project(String), single(String) }
  @FocusState private var deletionFocus: DeletionFocus?
  @FocusState private var restoreFocus: String?
  @State private var deletionOrigin: DeletionFocus?
  @State private var projectMenuFocus: (id: String, request: UUID)?
  @State private var query = ""
  @State private var project = ArchivedProjectFilter.all
  @State private var kind = ArchivedTaskKind.all
  @State private var sort = ArchivedTaskSort.updated
  private var presentation: ArchivedTaskPresentation {
    ArchivedTaskPresentation(library: store.library, runs: store.runs,
      automationTaskIDs: Set(store.automationPreferences.items.compactMap(\.taskID)))
  }
  var body: some View {
    let value = presentation
    let groups = value.groups(query: query, project: project, kind: kind, sort: sort)
    let grouped = value.effectiveFilter(project) == .all
    let showsEntries = !store.libraryLoading && store.libraryReadError == nil && !value.entries.isEmpty
    SettingsScrollPage(title: SettingsPage.archived.title, pinsControls: showsEntries) {
      if showsEntries {
        Button(role: .destructive) {
          requestDeletion(.all, ids: Set(value.entries.map(\.id)))
        } label: {
          Label("全部删除", systemImage: "trash")
        }.buttonStyle(ArchiveActionButtonStyle(kind: .deleteAll))
          .settingsActionFocus($deletionFocus, equals: .all,
            activate: { requestDeletion(.all, ids: Set(value.entries.map(\.id))) })
          .disabled(store.archiveActionsBusy).settingsSearchTarget(.archivedDeleteAll)
      }
    } controls: {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) { search; filters }
        VStack(spacing: 8) { search; HStack { filters; Spacer(minLength: 0) } }
      }
    } content: {
      if store.libraryLoading {
        ArchivedTasksStatusRow(kind: .loading)
      } else if store.libraryReadError != nil {
        ArchivedTasksStatusRow(kind: .failed)
      } else if value.entries.isEmpty {
        ArchivedTasksStatusRow(kind: .empty)
      } else if groups.isEmpty {
        ArchivedTasksStatusRow(kind: .noMatches)
      } else {
        ForEach(groups) { group in
          VStack(alignment: .leading, spacing: 8) {
            if grouped {
              HStack {
                Label(group.title, systemImage: "folder").appFont(.headline)
                  .lineLimit(1).help(group.project ?? "无项目")
                Spacer()
                Text("\(group.entries.count) 个任务").foregroundStyle(.secondary)
                if group.project != nil {
                  SettingsActionMenu(title: "\(group.title)归档任务操作",
                    actionTitle: "删除项目中的全部任务",
                    destructive: true, actionSystemImage: "trash",
                    focusRequest: projectMenuFocus?.id == group.id ? projectMenuFocus?.request : nil) {
                      requestDeletion(.project(group.id), ids: Set(group.entries.map(\.id)))
                    }.frame(width: 24, height: 24).disabled(store.archiveActionsBusy)
                }
              }.padding(.vertical, 8)
            }
            LazyVStack(spacing: 0) {
              ForEach(group.entries) { entry in
                row(entry, showProject: !grouped)
                Divider()
              }
            }
          }
        }
      }
    }
    .onSettingsConfirmationDismissal(store.archiveDeletion != nil, store: store, page: .archived) {
      let current = presentation.groups(query: query, project: project, kind: kind, sort: sort)
      switch deletionOrigin {
      case .all where !presentation.entries.isEmpty: deletionFocus = .all
      case .single(let id) where current.contains(where: { $0.entries.contains(where: { $0.id == id }) }):
        deletionFocus = .single(id)
      case .project(let id) where grouped && current.contains(where: { $0.id == id && $0.project != nil }):
        projectMenuFocus = (id, UUID())
      default: store.settingsSearchFocusRequest = UUID()
      }
      deletionOrigin = nil
    }
  }

  private func requestDeletion(_ origin: DeletionFocus, ids: Set<String>) {
    projectMenuFocus = nil
    deletionOrigin = origin
    let kind: ArchiveDeletionRequest.Kind
    switch origin {
    case .all: kind = .all
    case .single: kind = .single
    case .project: kind = .project
    }
    store.requestArchiveDeletion(kind, ids: ids)
  }

  private var search: some View {
    TextField("搜索已归档任务…", text: $query).textFieldStyle(.roundedBorder)
      .frame(minWidth: 180).accessibilityLabel("搜索已归档任务").settingsSearchTarget(.archivedSearch)
  }
  private var filters: some View {
    HStack(spacing: 8) {
      SettingsDropdownMenu(title: kind.title, accessibilityLabel: "筛选归档任务",
        systemImage: "line.3.horizontal.decrease", items: ArchivedTaskMenu.filters(kind: kind, sort: sort)) { choice in
          switch choice {
          case .kind(let selected): kind = selected
          case .sort(let selected): sort = selected
          }
        }.frame(width: 144, height: 24)
      SettingsDropdownMenu(title: projectTitle, accessibilityLabel: "按项目筛选归档任务",
        systemImage: "folder", items: ArchivedTaskMenu.projects(presentation, selection: project)) {
          project = $0
        }.frame(width: 176, height: 24)
    }
  }
  private var projectTitle: String {
    switch presentation.effectiveFilter(project) {
    case .all: "所有项目"
    case .project(let path): store.library.projectTitle(path)
    case .projectless: "无项目任务"
    case .automations: "计划任务"
    }
  }
  private func row(_ entry: ArchivedTaskEntry, showProject: Bool) -> some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 5) {
        Text(entry.task.title.isEmpty ? "未命名任务" : entry.task.title).fontWeight(.medium).lineLimit(1)
        HStack(spacing: 5) {
          if let date = entry.updatedAt {
            Text(date.formatted(date: .abbreviated, time: .shortened))
          } else { Text("时间未记录") }
          if showProject && !entry.task.project.isEmpty { Text("· " + entry.projectTitle) }
        }.appFont(.caption).foregroundStyle(.secondary).lineLimit(1)
      }.frame(maxWidth: .infinity, alignment: .leading)
      Button(role: .destructive) {
        requestDeletion(.single(entry.id), ids: [entry.id])
      } label: { Image(systemName: "trash") }
        .buttonStyle(ArchiveActionButtonStyle(kind: .deleteSingle)).help("永久删除此归档任务")
        .settingsActionFocus($deletionFocus, equals: .single(entry.id),
          activate: { requestDeletion(.single(entry.id), ids: [entry.id]) })
        .accessibilityLabel("删除归档任务：\(entry.task.title)")
        .disabled(store.archiveActionsBusy)
      Button {
        Task { await store.restoreArchivedTaskWithFeedback(entry.id) }
      } label: {
        ArchiveRestoreLabel(busy: store.restoringArchivedTaskIDs.contains(entry.id))
      }.buttonStyle(ArchiveActionButtonStyle(kind: .restore))
        .settingsActionFocus($restoreFocus, equals: entry.id,
          activate: { Task { await store.restoreArchivedTaskWithFeedback(entry.id) } })
        .disabled(store.archiveActionsBusy)
        .accessibilityLabel("\(store.restoringArchivedTaskIDs.contains(entry.id) ? "正在恢复任务" : "恢复任务")：\(entry.task.title)")
    }.padding(.vertical, 12)
  }
}
