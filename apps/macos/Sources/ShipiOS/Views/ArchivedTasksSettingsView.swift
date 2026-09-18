import SwiftUI

struct ArchivedTasksSettingsView: View {
  let store: WorkspaceStore
  private enum DeletionFocus: Hashable { case all, project(String), single(String) }
  @FocusState private var deletionFocus: DeletionFocus?
  @State private var deletionOrigin: DeletionFocus?
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
    SettingsScrollPage(title: SettingsPage.archived.title, pinsControls: !value.entries.isEmpty) {
      Button(role: .destructive) {
        requestDeletion(.all, ids: Set(value.entries.map(\.id)))
      } label: {
        Label("全部删除", systemImage: "trash")
      }.settingsConfirmationTriggerFocus($deletionFocus, equals: .all,
        activate: { requestDeletion(.all, ids: Set(value.entries.map(\.id))) })
        .disabled(value.entries.isEmpty).settingsSearchTarget(.archivedDeleteAll)
    } controls: {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) { search; filters }
        VStack(spacing: 8) { search; HStack { filters; Spacer(minLength: 0) } }
      }
    } content: {
      if value.entries.isEmpty {
        ContentUnavailableView("暂无已归档任务", systemImage: "archivebox",
          description: Text("归档的任务会保留在这里，恢复后重新显示在项目侧栏。"))
          .frame(maxWidth: .infinity)
      } else if groups.isEmpty {
        ContentUnavailableView("没有匹配的归档任务", systemImage: "magnifyingglass",
          description: Text(kind == .cloud ? "尚无云端归档任务。" : "尝试其他搜索词、项目或任务类型。"))
          .frame(maxWidth: .infinity)
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
                  Menu {
                    Button("删除项目中的全部任务", role: .destructive) {
                      requestDeletion(.project(group.id), ids: Set(group.entries.map(\.id)))
                    }
                  } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("\(group.title)归档任务操作")
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
      // SwiftUI Menu does not reliably accept restored FocusState focus on macOS.
      // Use the settings search until the action menu has a native focus bridge.
      case .project: store.settingsSearchFocusRequest = UUID()
      default: store.settingsSearchFocusRequest = UUID()
      }
      deletionOrigin = nil
    }
  }

  private func requestDeletion(_ origin: DeletionFocus, ids: Set<String>) {
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
      Menu {
        Picker("类型", selection: $kind) {
          ForEach(ArchivedTaskKind.allCases) { Text($0.title).tag($0) }
        }
        Divider()
        Picker("排序依据", selection: $sort) {
          ForEach(ArchivedTaskSort.allCases) { Text($0.title).tag($0) }
        }
      } label: { Label(kind.title, systemImage: "line.3.horizontal.decrease") }
        .frame(width: 130).accessibilityLabel("筛选归档任务")
      Menu {
        Picker("项目", selection: Binding(
          get: { presentation.effectiveFilter(project) }, set: { project = $0 })) {
          Text("所有项目").tag(ArchivedProjectFilter.all)
          ForEach(presentation.projects, id: \.path) { option in
            Text(option.title).help(option.path).tag(ArchivedProjectFilter.project(option.path))
          }
          Divider()
          Text("无项目任务").tag(ArchivedProjectFilter.projectless)
          Text("计划任务").tag(ArchivedProjectFilter.automations)
        }
      } label: { Label(projectTitle, systemImage: "folder").lineLimit(1) }
        .frame(width: 160).accessibilityLabel("按项目筛选归档任务")
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
        .buttonStyle(.borderless).help("永久删除此归档任务")
        .settingsConfirmationTriggerFocus($deletionFocus, equals: .single(entry.id),
          activate: { requestDeletion(.single(entry.id), ids: [entry.id]) })
        .accessibilityLabel("删除归档任务：\(entry.task.title)")
      Button {
        Task { await store.restoreArchivedTaskWithFeedback(entry.id) }
      } label: {
        if store.restoringArchivedTaskIDs.contains(entry.id) { ProgressView().controlSize(.small) }
        else { Text("恢复") }
      }.disabled(store.restoringArchivedTaskIDs.contains(entry.id))
        .accessibilityLabel("恢复任务：\(entry.task.title)")
    }.padding(.vertical, 12)
  }
}
