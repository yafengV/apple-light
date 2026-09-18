import AppKit
import SwiftUI

struct PluginSkillsView: View {
  @Bindable var store: WorkspaceStore
  var pluginID: String?
  var query = ""
  @State private var preview: PluginSkillReference?
  @State private var removing: PluginSkillReference?

  private var skills: [PluginSkillReference] {
    store.installedPluginSkills.filter { skill in
      let document = [skill.title, skill.id, skill.pluginName].joined(separator: " ")
      return (pluginID == nil || pluginID == skill.pluginID)
        && query.split(whereSeparator: \.isWhitespace).allSatisfy { document.localizedStandardContains(String($0)) }
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if store.pluginsLoading {
        ProgressView("正在读取技能…")
      } else if skills.isEmpty {
        ContentUnavailableView(query.isEmpty ? "尚未安装技能" : "没有匹配的技能",
          systemImage: "sparkles", description: Text("导入技能文件夹或包含技能的插件后，可以在这里查看和启停单个技能。"))
          .frame(maxWidth: .infinity)
      } else {
        ForEach(skills) { skill in
          HStack(spacing: 12) {
            Button { preview = skill } label: {
              VStack(alignment: .leading, spacing: 4) {
                Text(skill.title).appFont(.headline)
                Text(skill.pluginName + " · $" + skill.mention)
                  .appFont(.caption).foregroundStyle(.secondary)
              }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("查看技能：\(skill.title)")
              .contextMenu {
                Button("立即尝试") { _ = store.trySkill(skill.id) }
                  .disabled(!store.canTrySkill(skill.id))
                if skill.isStandalone {
                  Button("卸载技能", role: .destructive) { removing = skill }
                    .disabled(!store.pluginsLoaded)
                }
              }
            let parentEnabled = skill.isStandalone || store.pluginPreferences.installed.first { $0.id == skill.pluginID }?.enabled == true
            if !parentEnabled { Text("插件已停用").appFont(.caption).foregroundStyle(.secondary) }
            Toggle("启用技能", isOn: Binding(
              get: { !store.pluginPreferences.disabledSkillIDs.contains(skill.id) },
              set: { _ = store.setSkillEnabled($0, id: skill.id) }))
              .labelsHidden().accessibilityLabel("启用技能：\(skill.title)")
              .disabled(!store.pluginsLoaded || !store.pluginsEnabled || !parentEnabled)
          }.padding(.vertical, 6)
          Divider()
        }
      }
    }
    .sheet(item: $preview) { skill in
      PluginSkillPreview(store: store, skill: skill)
    }
    .alert("卸载技能？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
      Button("取消", role: .cancel) { removing = nil }
      Button("卸载技能", role: .destructive) {
        if let skill = removing { _ = store.removeStandaloneSkill(skill.id) }
        removing = nil
      }
    } message: { Text("仅移除 ShipiOS 中的副本，原始技能文件夹保持不变。") }
  }
}

private struct PluginSkillPreview: View {
  let store: WorkspaceStore
  let skill: PluginSkillReference
  @Environment(\.dismiss) private var dismiss
  @State private var source: String?
  @State private var error: String?
  @State private var showSource = false
  @State private var reload = UUID()
  @State private var actionError: String?
  @State private var confirmingRemoval = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text(skill.title).appFont(.title2, weight: .semibold)
        Spacer()
        Picker("内容格式", selection: $showSource) {
          Text("预览").tag(false)
          Text("源文件").tag(true)
        }.pickerStyle(.segmented).frame(width: 160)
        Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      Text(skill.pluginName + " · $" + skill.mention).foregroundStyle(.secondary).textSelection(.enabled)
      ScrollView {
        if let source {
          if showSource {
            Text(source).appFont(.body, design: .monospaced).textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          } else {
            MessageMarkdownView(source: source) { url in
              if ["https", "http"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
            }
          }
        } else if let error {
          Text(error).foregroundStyle(.red).textSelection(.enabled)
          Button("重试") { reload = UUID() }
        } else { ProgressView("正在读取技能…") }
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
      if let actionError { Text(actionError).foregroundStyle(.red).textSelection(.enabled) }
      HStack {
        Toggle("启用技能", isOn: Binding(
          get: { !store.pluginPreferences.disabledSkillIDs.contains(skill.id) },
          set: { enabled in
            actionError = store.setSkillEnabled(enabled, id: skill.id) ? nil : store.pluginsError
          }))
          .disabled(!store.pluginsLoaded || !store.pluginsEnabled
            || (!skill.isStandalone && store.pluginPreferences.installed.first(where: { $0.id == skill.pluginID })?.enabled != true))
        if skill.isStandalone {
          Button("卸载技能", role: .destructive) { confirmingRemoval = true }
            .disabled(!store.pluginsLoaded)
        }
        Spacer()
        Button("立即尝试") {
          if store.trySkill(skill.id) { dismiss() }
          else { actionError = store.pluginsError }
        }.buttonStyle(.borderedProminent)
          .disabled(source == nil || !store.canTrySkill(skill.id))
      }
    }.padding(24).frame(minWidth: 580, idealWidth: 680, minHeight: 400, idealHeight: 560)
      .alert("卸载技能？", isPresented: $confirmingRemoval) {
        Button("取消", role: .cancel) {}
        Button("卸载技能", role: .destructive) {
          if store.removeStandaloneSkill(skill.id) { dismiss() }
          else { actionError = store.pluginsError }
        }
      } message: { Text("仅移除 ShipiOS 中的副本，原始技能文件夹保持不变。") }
      .task(id: reload) {
        source = nil
        error = nil
        let id = skill.id, root = store.dataRoot
        do {
          let text = try await Task.detached(priority: .userInitiated) {
            try PluginStorage.readSkill(id: id, root: root)
          }.value
          guard !Task.isCancelled else { return }
          source = text
        } catch {
          guard !Task.isCancelled else { return }
          self.error = error.localizedDescription
        }
      }
  }
}
