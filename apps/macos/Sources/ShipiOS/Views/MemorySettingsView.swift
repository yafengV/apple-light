import SwiftUI

struct MemorySettingsView: View {
  @Bindable var store: WorkspaceStore
  private enum DeletionFocus: Hashable { case single(UUID), all }
  @FocusState private var deletionFocus: DeletionFocus?
  @State private var deletionOrigin: DeletionFocus?
  @State private var editingID: UUID?
  @State private var editingText = ""

  var body: some View {
    Form {
      Section("记忆") {
        SettingsToggle(
          title: "启用记忆",
          description: "启用后，已保存的长期记忆会随下一次模型请求发送给你配置的 API 服务。关闭不会删除内容。",
          isOn: Binding(
            get: { store.memoryPreferences.enabled },
            set: { _ = store.saveMemoryEnabled($0) })
        ).disabled(!store.memoriesLoaded).settingsSearchTarget(.memoryEnabled)
      }

      Section("添加记忆") {
        SettingsTextEditor(text: $store.memoryDraft, label: "新记忆")
          .appFont(size: 13).frame(minHeight: 72)
          .accessibilityLabel("新记忆").settingsSearchTarget(.memoryAdd)
          .disabled(!store.memoriesLoaded)
        HStack {
          Spacer()
          Text("\(store.memoryDraft.utf8.count) / \(MemoryStorage.maximumItemBytes) 字节")
            .appFont(.caption).foregroundStyle(.secondary)
          Button("添加") { _ = store.addMemory(store.memoryDraft) }
            .disabled(
              !store.memoriesLoaded
                || store.memoryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || store.memoryDraft.utf8.count > MemoryStorage.maximumItemBytes)
        }
      }

      Section("已保存的记忆") {
        if store.memoryPreferences.items.isEmpty {
          ContentUnavailableView(
            "暂无记忆", systemImage: "brain",
            description: Text("在上方添加需要跨会话保留的偏好或项目背景。"))
        } else {
          ForEach(store.memoryPreferences.items.sorted { $0.updatedAt > $1.updatedAt }) { memory in
            VStack(alignment: .leading, spacing: 10) {
              if editingID == memory.id {
                SettingsTextEditor(text: $editingText, label: "编辑记忆").frame(minHeight: 70)
                  .accessibilityLabel("编辑记忆")
                HStack {
                  Button("取消") { cancelEditing() }
                  Button("保存") {
                    if store.updateMemory(memory.id, text: editingText) { cancelEditing() }
                  }.disabled(
                    editingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || editingText.utf8.count > MemoryStorage.maximumItemBytes)
                }
              } else {
                Text(memory.text).appFont(.body).textSelection(.enabled)
                HStack {
                  Text(memory.updatedAt, style: .date).appFont(.caption).foregroundStyle(.tertiary)
                  Spacer()
                  Button("编辑") {
                    editingID = memory.id
                    editingText = memory.text
                  }.buttonStyle(.plain)
                  Button(role: .destructive) {
                    requestDeletion(memory.id)
                  } label: {
                    Image(systemName: "trash")
                  }.buttonStyle(.plain)
                    .settingsActionFocus($deletionFocus, equals: .single(memory.id),
                      activate: { requestDeletion(memory.id) })
                    .help("删除记忆")
                    .accessibilityLabel("删除记忆")
                }
              }
            }.padding(.vertical, 5)
          }
          HStack {
            Text("共 \(store.memoryPreferences.items.count) 条")
              .appFont(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("清空全部…", role: .destructive) {
              requestDeletion()
            }.settingsActionFocus($deletionFocus, equals: .all, activate: { requestDeletion() })
          }
        }
      }.disabled(!store.memoriesLoaded).settingsSearchTarget(.memorySaved)

      if let error = store.memoryError {
        Section {
          Text(error).foregroundStyle(.red).textSelection(.enabled)
          Button("重新加载") { Task { await store.loadMemories() } }
            .disabled(store.memoriesLoading)
        }
      }
    }.settingsFormStyle().appSurface()
      .onSettingsConfirmationDismissal(store.memoryDeletion != nil, store: store, page: .memories) {
        if let origin = deletionOrigin, store.memoriesLoaded,
          !store.memoryPreferences.items.isEmpty {
          if case .single(let id) = origin, !store.memoryPreferences.items.contains(where: { $0.id == id }) {
            store.settingsSearchFocusRequest = UUID()
          } else { deletionFocus = origin }
        } else { store.settingsSearchFocusRequest = UUID() }
        deletionOrigin = nil
      }
      .onChange(of: store.memoryPreferences.items.map(\.id)) { _, ids in
        if let editingID, !ids.contains(editingID) { cancelEditing() }
      }
  }

  private func requestDeletion(_ id: UUID? = nil) {
    deletionOrigin = id.map(DeletionFocus.single) ?? .all
    store.requestMemoryDeletion(id)
  }

  private func cancelEditing() {
    editingID = nil
    editingText = ""
  }
}
