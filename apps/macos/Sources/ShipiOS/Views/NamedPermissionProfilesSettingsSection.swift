import SwiftUI

/// The editor stays in the main settings page. Validation uses the bundled
/// Agent's pinned Codex Core before a profile is offered in task menus.
struct NamedPermissionProfilesSettingsSection: View {
  @Bindable var store: WorkspaceStore
  @State private var editingID: String?
  @State private var draftID = ""
  @State private var draftDescription = ""
  @State private var draftTOML = ""
  @State private var showingEditor = false
  @State private var validating = false
  @State private var deletionID: String?
  @State private var status = ""

  var body: some View {
    Section("命名权限档案") {
      Text("在此应用中保存独立的 Codex Core 权限档案。新任务可在权限菜单中选择；已有任务保留选择时的配置快照。")
        .appFont(.caption).foregroundStyle(.secondary)
      ForEach(store.library.namedPermissionProfiles) { profile in
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text(profile.id)
            if !profile.description.isEmpty {
              Text(profile.description).appFont(.caption).foregroundStyle(.secondary)
            }
            if profile.requiresFullAccess {
              Text("需先开启完全访问，才可用于新任务")
                .appFont(.caption).foregroundStyle(.secondary)
            }
          }
          Spacer()
          Button("编辑") { edit(profile) }
          Button("删除") { deletionID = profile.id }
        }
      }
      Button("添加权限档案") {
        editingID = nil
        draftID = "my-profile"
        draftDescription = ""
        draftTOML = "[permissions.my-profile]\nextends = \":workspace-write\"\n"
        showingEditor = true
        status = ""
      }
      .settingsSearchTarget(.generalNamedPermissions)
      if showingEditor {
        VStack(alignment: .leading, spacing: 8) {
          Text(editingID == nil ? "新建权限档案" : "编辑权限档案").font(.headline)
          TextField("档案 ID", text: $draftID)
            .disabled(editingID != nil)
          TextField("说明（可选）", text: $draftDescription)
          Text("权限配置 TOML").appFont(.caption).foregroundStyle(.secondary)
          TextEditor(text: $draftTOML)
            .font(.system(.body, design: .monospaced))
            .frame(minHeight: 150)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
          Text("ID 需与 [permissions.<ID>] 一致；仅允许权限配置，模型和凭据继续由 ShipiOS 独立管理。")
            .appFont(.caption).foregroundStyle(.secondary)
          HStack {
            Button("保存并验证") { save() }.disabled(validating || !store.libraryLoaded)
            Button("取消") { showingEditor = false; status = "" }.disabled(validating)
            if validating { ProgressView().controlSize(.small) }
          }
        }
      }
      if !status.isEmpty { Text(status).appFont(.caption).foregroundStyle(.secondary) }
    }
    .alert("删除权限档案？", isPresented: Binding(
      get: { deletionID != nil }, set: { if !$0 { deletionID = nil } })) {
        Button("取消", role: .cancel) { deletionID = nil }
        Button("删除", role: .destructive) {
          if let deletionID {
            status = store.deleteNamedPermissionProfile(deletionID)
              ? "已删除权限档案；已有任务的配置快照保持不变。"
              : (store.generalSettingsError ?? "删除失败，请重试。")
          }
          deletionID = nil
        }
      } message: {
        Text("此档案将从新任务的权限菜单移除。已有任务保留自己的配置快照。")
      }
  }

  private func edit(_ profile: AgentNamedPermissionProfile) {
    editingID = profile.id
    draftID = profile.id
    draftDescription = profile.description
    draftTOML = profile.configTOML
    showingEditor = true
    status = ""
  }

  private func save() {
    let profile = AgentNamedPermissionProfile(id: draftID.trimmingCharacters(in: .whitespacesAndNewlines),
      description: draftDescription.trimmingCharacters(in: .whitespacesAndNewlines),
      configTOML: draftTOML)
    validating = true
    Task {
      let saved = await store.validateAndSaveNamedPermissionProfile(profile)
      validating = false
      if saved {
        showingEditor = false
        status = store.library.namedPermissionProfiles.first(where: { $0.id == profile.id })?
          .requiresFullAccess == true
          ? "已保存并验证；此档案需要先开启完全访问，才可用于新任务。"
          : "已保存并验证权限档案。"
      } else {
        status = store.generalSettingsError ?? "权限档案无效，请检查配置。"
      }
    }
  }
}
