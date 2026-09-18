import SwiftUI

struct MemorySettingsView: View {
  @Bindable var store: WorkspaceStore
  private enum DeletionFocus: Hashable { case single(UUID), all }
  @State private var deletionOrigin: DeletionFocus?
  @State private var menuFocus: (origin: DeletionFocus, request: UUID)?
  @State private var editingID: UUID?
  @State private var editingText = ""
  @State private var editorFocusRequest: UUID?
  @State private var editReturnRequest = UUID()
  @State private var query = ""
  @State private var sort = MemoryListSort.newest
  @FocusState private var searchFocused: Bool
  @FocusState private var editFocus: UUID?

  private var presentation: MemoryListPresentation {
    .init(preferences: store.memoryPreferences, loaded: store.memoriesLoaded,
      loading: store.memoriesLoading, query: query, sort: sort)
  }

  var body: some View {
    SettingsScrollPage(title: SettingsPage.memories.title) {} controls: {} content: {
      Form {
        Section {
          SettingsToggle(
            title: "启用记忆",
            description: "启用后，已保存的长期记忆会随下一次模型请求发送给你配置的 API 服务。关闭不会删除内容。",
            isOn: Binding(get: { store.memoryPreferences.enabled },
              set: { _ = store.saveMemoryEnabled($0) })
          ).disabled(!store.memoriesLoaded).settingsSearchTarget(.memoryEnabled)
        }
      }.settingsFormStyle()
      savedMemories.settingsSearchTarget(.memorySaved)
      addMemory
    }
    .onSettingsConfirmationDismissal(store.memoryDeletion != nil, store: store, page: .memories) {
      if let origin = deletionOrigin, store.memoriesLoaded {
        switch origin {
        case .all where !store.memoryPreferences.items.isEmpty: menuFocus = (origin, UUID())
        case .single(let id) where presentation.items.contains(where: { $0.id == id }):
          menuFocus = (origin, UUID())
        default: searchFocused = true
        }
      } else { store.settingsSearchFocusRequest = UUID() }
      deletionOrigin = nil
    }
    .onChange(of: store.memoryPreferences.items.map(\.id)) { _, ids in
      if let editingID, !ids.contains(editingID) { cancelEditing() }
    }
  }

  private var savedMemories: some View {
    let value = presentation
    return VStack(alignment: .leading, spacing: 12) {
      Text("已保存的记忆").appFont(size: 16, weight: .semibold)
      HStack(spacing: 8) {
        TextField("搜索记忆", text: $query).textFieldStyle(.roundedBorder)
          .accessibilityLabel("搜索记忆").focused($searchFocused)
          .frame(maxWidth: 320)
        Spacer(minLength: 0)
        SettingsDropdownMenu(title: sort.title, accessibilityLabel: "记忆排序",
          systemImage: "arrow.up.arrow.down", compact: true,
          items: [.section("排序")] + MemoryListSort.allCases.map {
            .option(.init(value: $0, title: $0.title, selected: $0 == sort))
          }) { sort = $0 }.frame(width: 28, height: 28)
        SettingsActionMenu(title: "记忆更多选项", actionTitle: "删除全部记忆",
          destructive: true, actionSystemImage: "trash", focusRequest: focusRequest(.all)) {
            requestDeletion()
          }.frame(width: 28, height: 28)
          .disabled(!store.memoriesLoaded || store.memoryPreferences.items.isEmpty)
      }.disabled(store.memoriesLoading)
      Divider()
      switch value.state {
      case .loading:
        status("正在加载记忆…", id: "loading")
      case .failed:
        VStack(spacing: 8) {
          Text("无法加载记忆").foregroundStyle(.secondary)
          if let error = store.memoryError { Text(error).appFont(.caption).foregroundStyle(.secondary) }
          Button("重试") { Task { await store.loadMemories() } }
            .buttonStyle(SettingsActionButtonStyle())
        }.frame(maxWidth: .infinity, minHeight: 80).accessibilityIdentifier("memory-list-failed")
      case .empty: status("暂无已保存的记忆", id: "empty")
      case .noMatches(let query): status("未找到与“\(query)”匹配的记忆", id: "no-matches")
      case .ready:
        LazyVStack(spacing: 0) {
          ForEach(value.items) { memory in
            row(memory)
            if memory.id != value.items.last?.id { Divider() }
          }
        }
      }
      if store.memoriesLoaded, let error = store.memoryError {
        Text(error).appFont(size: 13).foregroundStyle(.red).textSelection(.enabled)
          .accessibilityIdentifier("memory-write-error")
      }
    }
  }

  private func status(_ title: String, id: String) -> some View {
    Text(title).appFont(size: 13).foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, minHeight: 80)
      .accessibilityIdentifier("memory-list-" + id)
  }

  private func row(_ memory: SavedMemory) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if editingID == memory.id {
        SettingsTextEditor(text: $editingText, label: "编辑记忆", focusRequest: editorFocusRequest)
          .frame(minHeight: 70)
        HStack {
          Spacer()
          Button("取消") { finishEditing(memory.id) }
          Button("保存") {
            if store.updateMemory(memory.id, text: editingText) { finishEditing(memory.id) }
          }.disabled(editingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || editingText.utf8.count > MemoryStorage.maximumItemBytes)
        }.buttonStyle(SettingsActionButtonStyle())
      } else {
        HStack(spacing: 12) {
          Text(memory.text).appFont(size: 13).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
          Button { beginEditing(memory) } label: { Image(systemName: "pencil") }
            .buttonStyle(.plain).help("编辑记忆")
            .accessibilityLabel("编辑记忆：\(memory.text.prefix(130))")
            .settingsActionFocus($editFocus, equals: memory.id, activate: { beginEditing(memory) })
          SettingsActionMenu(title: "记忆选项：\(memory.text.prefix(130))", actionTitle: "删除",
            destructive: true, actionSystemImage: "trash", focusRequest: focusRequest(.single(memory.id))) {
              requestDeletion(memory.id)
            }.frame(width: 28, height: 28)
            .help("更新于 \(memory.updatedAt.formatted(date: .abbreviated, time: .shortened))")
        }
      }
    }.padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 48)
      .disabled(!store.memoriesLoaded || store.memoriesLoading || store.deletingMemories)
  }

  private var addMemory: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("添加记忆").appFont(size: 16, weight: .semibold)
      SettingsTextEditor(text: $store.memoryDraft, label: "新记忆",
        placeholder: "添加需要跨会话保留的偏好或项目背景")
        .frame(height: 72).settingsSearchTarget(.memoryAdd)
      HStack {
        Text("\(store.memoryDraft.utf8.count) / \(MemoryStorage.maximumItemBytes) 字节")
          .appFont(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("添加") { _ = store.addMemory(store.memoryDraft) }
          .buttonStyle(SettingsActionButtonStyle())
          .disabled(store.memoryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || store.memoryDraft.utf8.count > MemoryStorage.maximumItemBytes)
      }
    }.disabled(!store.memoriesLoaded || store.memoriesLoading)
  }

  private func focusRequest(_ origin: DeletionFocus) -> UUID? {
    menuFocus?.origin == origin ? menuFocus?.request : nil
  }
  private func requestDeletion(_ id: UUID? = nil) {
    menuFocus = nil
    deletionOrigin = id.map(DeletionFocus.single) ?? .all
    store.requestMemoryDeletion(id)
  }
  private func beginEditing(_ memory: SavedMemory) {
    editReturnRequest = UUID()
    editingID = memory.id
    editingText = memory.text
    editorFocusRequest = UUID()
  }
  private func finishEditing(_ id: UUID) {
    cancelEditing()
    let request = UUID()
    editReturnRequest = request
    // The edit button is mounted only after the editor has been removed.
    DispatchQueue.main.async {
      guard editReturnRequest == request, editingID == nil,
        store.destination == .settings, store.settingsPage == .memories,
        !store.hasSettingsConfirmation, store.presentedOverlay == nil else { return }
      if presentation.items.contains(where: { $0.id == id }) { editFocus = id }
      else { searchFocused = true }
    }
  }
  private func cancelEditing() { editingID = nil; editingText = "" }
}
