import AppKit
import SwiftUI

struct PluginSkillsView: View {
  enum Layout { case rows, cards }

  @Bindable var store: WorkspaceStore
  var pluginID: String?
  var query = ""
  var layout: Layout = .rows
  var sourceSkills: [PluginSkillReference]?
  var projectPathsBySkillID: [String: String] = [:]
  var emptyTitle = "尚未安装技能"
  var emptyDescription = "导入技能文件夹或包含技能的插件后，可以在这里查看和启停单个技能。"
  @State private var preview: PluginSkillReference?
  @State private var editing: PluginSkillReference?
  @State private var removing: PluginSkillReference?

  private var skills: [PluginSkillReference] {
    (sourceSkills ?? store.installedPluginSkills).filter { skill in
      let document = [skill.title, skill.summary, skill.id, skill.pluginName].joined(separator: " ")
      return (pluginID == nil || pluginID == skill.pluginID)
        && query.split(whereSeparator: \.isWhitespace).allSatisfy { document.localizedStandardContains(String($0)) }
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if store.pluginsLoading {
        ProgressView("正在读取技能…")
      } else if skills.isEmpty {
        ContentUnavailableView(query.isEmpty ? emptyTitle : "没有匹配的技能",
          systemImage: "sparkles", description: Text(emptyDescription))
          .frame(maxWidth: .infinity)
      } else if layout == .cards {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
          ForEach(skills) { skill in skillCard(skill) }
        }
      } else {
        ForEach(skills) { skill in
          HStack(spacing: 12) {
            SkillIconView(skill: skill, size: 32, fallbackColor: store.appearance.accentColor,
              revision: store.repositorySkillRevision)
            Button { preview = skill } label: {
              VStack(alignment: .leading, spacing: 4) {
                Text(skill.title).appFont(.headline)
                if !skill.summary.isEmpty {
                  Text(skill.summary).appFont(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(2)
                }
                Text(skill.pluginName + " · $" + skill.mention)
                  .appFont(.caption).foregroundStyle(.secondary)
              }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("查看技能：\(skill.title)")
              .contextMenu {
                Button("立即尝试") { Task { _ = await store.trySkill(skill.id, projectPath: projectPathsBySkillID[skill.id]) } }
                  .disabled(!store.canTrySkill(skill.id, projectPath: projectPathsBySkillID[skill.id]))
                if skill.isStandalone || skill.isRepository {
                  Button("编辑") { editing = skill }
                    .accessibilityLabel("编辑技能：\(skill.title)")
                }
                if skill.isStandalone {
                  Button("卸载技能", role: .destructive) { removing = skill }
                    .disabled(!store.pluginsLoaded)
                }
              }
            let parentEnabled = skill.isStandalone || skill.isRepository
              || store.pluginPreferences.installed.first { $0.id == skill.pluginID }?.enabled == true
            if !parentEnabled { Text("插件已停用").appFont(.caption).foregroundStyle(.secondary) }
            if skill.isStandalone || skill.isRepository {
              Button("编辑") { editing = skill }
                .disabled(!store.pluginsLoaded)
                .accessibilityLabel("编辑技能：\(skill.title)")
            }
            Toggle("启用技能", isOn: Binding(
              get: { store.isSkillEnabled(skill) },
              set: { _ = store.setSkillEnabled($0, skill: skill, projectPath: projectPathsBySkillID[skill.id]) }))
              .labelsHidden().accessibilityLabel("启用技能：\(skill.title)")
              .disabled(!store.pluginsLoaded || !store.pluginsEnabled || !parentEnabled)
          }.padding(.vertical, 6)
          Divider()
        }
      }
    }
    .sheet(item: $preview) { skill in
      PluginSkillPreview(store: store, skill: skill, projectPath: projectPathsBySkillID[skill.id])
    }
    .onChange(of: skills) { _, updated in
      if let id = preview?.id { preview = updated.first { $0.id == id } }
    }
    .sheet(item: $editing) { skill in
      SkillEditorView(store: store, skill: skill, contextProjectPath: projectPathsBySkillID[skill.id])
    }
    .alert("卸载技能？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
      Button("取消", role: .cancel) { removing = nil }
      Button("卸载技能", role: .destructive) {
        if let skill = removing { _ = store.removeStandaloneSkill(skill.id) }
        removing = nil
      }
    } message: { Text("仅移除 ShipiOS 中的副本，原始技能文件夹保持不变。") }
  }

  private func skillCard(_ skill: PluginSkillReference) -> some View {
    let parentEnabled = skill.isStandalone || skill.isRepository
      || store.pluginPreferences.installed.first { $0.id == skill.pluginID }?.enabled == true
    return VStack(alignment: .leading, spacing: 12) {
      Button { preview = skill } label: {
        HStack(alignment: .top, spacing: 12) {
          SkillIconView(skill: skill, fallbackColor: store.appearance.accentColor,
            revision: store.repositorySkillRevision)
          VStack(alignment: .leading, spacing: 6) {
            Text(skill.title).appFont(.headline)
            if !skill.summary.isEmpty {
              Text(skill.summary).appFont(.subheadline).foregroundStyle(.secondary)
                .lineLimit(2)
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
        }.contentShape(Rectangle())
      }.buttonStyle(.plain).accessibilityLabel("查看技能：\(skill.title)")

      Spacer(minLength: 0)
      Text(skill.pluginName + " · $" + skill.mention)
        .appFont(.caption).foregroundStyle(.secondary).lineLimit(1)
      HStack {
        if !parentEnabled { Text("插件已停用").appFont(.caption).foregroundStyle(.secondary) }
        Toggle("启用技能", isOn: Binding(
          get: { store.isSkillEnabled(skill) },
          set: { _ = store.setSkillEnabled($0, skill: skill, projectPath: projectPathsBySkillID[skill.id]) }))
          .labelsHidden().accessibilityLabel("启用技能：\(skill.title)")
          .disabled(!store.pluginsLoaded || !store.pluginsEnabled || !parentEnabled)
        Spacer()
        Button("立即尝试") { Task { _ = await store.trySkill(skill.id, projectPath: projectPathsBySkillID[skill.id]) } }
          .disabled(!store.canTrySkill(skill.id, projectPath: projectPathsBySkillID[skill.id]))
        if skill.isStandalone || skill.isRepository {
          Button("编辑") { editing = skill }
            .disabled(!store.pluginsLoaded)
            .accessibilityLabel("编辑技能：\(skill.title)")
        }
        if skill.isStandalone {
          Menu {
            Button("卸载技能", role: .destructive) { removing = skill }
          } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("技能菜单：\(skill.title)")
        }
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, minHeight: 165, alignment: .leading)
    .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
  }
}

private struct SkillEditorView: View {
  let store: WorkspaceStore
  let skill: PluginSkillReference
  var contextProjectPath: String? = nil
  @Environment(\.dismiss) private var dismiss
  @State private var original: String?
  @State private var draft = ""
  @State private var error: String?
  @State private var reload = UUID()
  @State private var confirmingDiscard = false
  @State private var confirmingReload = false

  private var changed: Bool { original != nil && draft != original }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("编辑技能：\(skill.title)").appFont(.title2, weight: .semibold)
        Spacer()
        Button("重新载入") {
          if changed { confirmingReload = true }
          else { reload = UUID() }
        }.disabled(original == nil && error == nil)
      }
      Text(skill.fileURL.path).appFont(.caption).foregroundStyle(.secondary)
        .textSelection(.enabled)
      if original == nil && error == nil {
        ProgressView("正在读取技能…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        TextEditor(text: $draft)
          .appFont(.body, design: .monospaced)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .border(.secondary.opacity(0.3))
          .disabled(original == nil)
      }
      if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
      HStack {
        Spacer()
        Button("取消") {
          if changed { confirmingDiscard = true }
          else { dismiss() }
        }.keyboardShortcut(.cancelAction)
        Button("保存") {
          guard let original else { return }
          let saved: Bool
          if let project = skill.repositoryRoot {
            saved = store.updateRepositorySkill(id: skill.id, text: draft,
              expectedOriginal: original, project: project, contextProjectPath: contextProjectPath)
          } else {
            saved = store.updateStandaloneSkill(id: skill.id, text: draft,
              expectedOriginal: original)
          }
          if saved {
            dismiss()
          } else { error = store.pluginsError ?? "无法保存技能。" }
        }.buttonStyle(.borderedProminent).disabled(!changed)
      }
    }
    .padding(24)
    .frame(minWidth: 620, idealWidth: 720, minHeight: 440, idealHeight: 580)
    .interactiveDismissDisabled(changed)
    .alert("放弃未保存的修改？", isPresented: $confirmingDiscard) {
      Button("继续编辑", role: .cancel) {}
      Button("放弃修改", role: .destructive) { dismiss() }
    }
    .alert("重新载入磁盘版本？", isPresented: $confirmingReload) {
      Button("继续编辑", role: .cancel) {}
      Button("重新载入", role: .destructive) { reload = UUID() }
    } message: { Text("当前未保存的修改会被丢弃。") }
    .task(id: reload) {
      original = nil
      error = nil
      let id = skill.id, root = store.dataRoot, repositoryRoot = skill.repositoryRoot
      do {
        let text = try await Task.detached(priority: .userInitiated) {
          try PluginStorage.readSkill(id: id, root: root, repositoryRoot: repositoryRoot)
        }.value
        guard !Task.isCancelled else { return }
        original = text
        draft = text
      } catch {
        guard !Task.isCancelled else { return }
        self.error = error.localizedDescription
      }
    }
  }
}

private struct PluginSkillPreview: View {
  let store: WorkspaceStore
  let skill: PluginSkillReference
  var projectPath: String? = nil
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
        SkillIconView(skill: skill, large: true, size: 44, fallbackColor: store.appearance.accentColor,
          revision: store.repositorySkillRevision)
        Text(skill.title).appFont(.title2, weight: .semibold)
        Spacer()
        Picker("内容格式", selection: $showSource) {
          Text("预览").tag(false)
          Text("源文件").tag(true)
        }.pickerStyle(.segmented).frame(width: 160)
        Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      Text(skill.pluginName + " · $" + skill.mention).foregroundStyle(.secondary).textSelection(.enabled)
      if !skill.summary.isEmpty {
        Text(skill.summary).foregroundStyle(.secondary).textSelection(.enabled)
      }
      if let prompt = skill.interface.defaultPrompt {
        VStack(alignment: .leading, spacing: 4) {
          Text("默认提示").appFont(.caption).foregroundStyle(.secondary)
          Text(prompt).textSelection(.enabled).lineLimit(3)
        }
      }
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
          get: { store.isSkillEnabled(skill) },
          set: { enabled in
            actionError = store.setSkillEnabled(enabled, skill: skill, projectPath: projectPath) ? nil : store.pluginsError
          }))
          .disabled(!store.pluginsLoaded || !store.pluginsEnabled
            || (!skill.isStandalone && !skill.isRepository && store.pluginPreferences.installed.first(where: { $0.id == skill.pluginID })?.enabled != true))
        if skill.isStandalone {
          Button("卸载技能", role: .destructive) { confirmingRemoval = true }
            .disabled(!store.pluginsLoaded)
        }
        Spacer()
        Button("立即尝试") {
          Task {
            if await store.trySkill(skill.id, projectPath: projectPath) { dismiss() }
            else { actionError = store.pluginsError }
          }
        }.buttonStyle(.borderedProminent)
          .disabled(source == nil || !store.canTrySkill(skill.id, projectPath: projectPath))
      }
    }.padding(24).frame(minWidth: 580, idealWidth: 680, minHeight: 400, idealHeight: 560)
      .alert("卸载技能？", isPresented: $confirmingRemoval) {
        Button("取消", role: .cancel) {}
        Button("卸载技能", role: .destructive) {
          if store.removeStandaloneSkill(skill.id) { dismiss() }
          else { actionError = store.pluginsError }
        }
      } message: { Text("仅移除 ShipiOS 中的副本，原始技能文件夹保持不变。") }
      .task(id: "\(reload)|\(store.repositorySkillRevision)") {
        source = nil
        error = nil
        let id = skill.id, root = store.dataRoot, repositoryRoot = skill.repositoryRoot
        do {
          let text = try await Task.detached(priority: .userInitiated) {
            try PluginStorage.readSkill(id: id, root: root, repositoryRoot: repositoryRoot)
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
