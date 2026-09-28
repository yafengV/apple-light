import SwiftUI

struct SkillsView: View {
  @Bindable var store: WorkspaceStore
  private var query: String { store.skillLibraryQuery }
  @State private var creating = false
  @State private var repositoryLibrary = RepositorySkillLibrary()
  @State private var projectLoading = false
  @State private var projectReload = UUID()
  @State private var projectLoadToken = UUID()

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 12) {
        Text("技能").appFont(.title2, weight: .semibold)
        Text("\(store.installedPluginSkills.count + repositoryLibrary.skills.count)")
          .appFont(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("新建技能") { creating = true }
          .disabled(!store.pluginsLoaded)
        Button("导入技能…") { store.chooseStandaloneSkillFolder() }
          .disabled(!store.pluginsLoaded)
        Button("重新加载") { Task { await store.loadPlugins() } }
          .disabled(store.pluginsLoading)
        Button("返回任务") { store.returnToWorkspace() }
          .keyboardShortcut(.cancelAction)
      }

      TextField("搜索技能", text: $store.skillLibraryQuery)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("搜索技能")

      if !store.pluginsEnabled {
        Label("插件与技能已在设置中关闭", systemImage: "info.circle")
          .foregroundStyle(.secondary)
      }

      ScrollView {
        Text("项目技能").appFont(.headline)
          .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 8)
        if projectLoading {
          ProgressView("正在读取项目技能…")
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
          PluginSkillsView(store: store, query: query, layout: .cards,
            sourceSkills: repositoryLibrary.skills,
            projectPathsBySkillID: repositoryLibrary.projectPathsBySkillID,
            emptyTitle: "保存的项目中没有技能",
            emptyDescription: "打开项目或创建项目技能后，可以在这里统一浏览。")
            .frame(maxWidth: .infinity, alignment: .leading)
          ForEach(repositoryLibrary.issues) { issue in
            HStack {
              Text(URL(fileURLWithPath: issue.projectPath).lastPathComponent + "：" + issue.message)
                .foregroundStyle(.red).textSelection(.enabled)
              Button("重试") { projectReload = UUID() }
            }.frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        Divider().padding(.vertical, 16)
        Text("已安装").appFont(.headline)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.bottom, 8)
        PluginSkillsView(store: store, query: query, layout: .cards)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      if let error = store.pluginsError {
        HStack(alignment: .top) {
          Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
          Text(error).textSelection(.enabled)
          Spacer()
          Button("重试") { Task { await store.loadPlugins() } }
            .disabled(store.pluginsLoading)
        }.padding(12)
          .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
      }
    }
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task { if !store.pluginsLoaded { await store.loadPlugins() } }
    .task(id: store.skillLibraryProjectPaths + [store.repositorySkillRevision.uuidString, projectReload.uuidString]) {
      let request = UUID()
      projectLoadToken = request
      projectLoading = true
      defer { if projectLoadToken == request { projectLoading = false } }
      let paths = store.skillLibraryProjectPaths
      let loaded = await Task.detached(priority: .userInitiated) {
        PluginStorage.repositorySkillLibrary(projectPaths: paths)
      }.value
      guard !Task.isCancelled, projectLoadToken == request else { return }
      repositoryLibrary = loaded
    }
    .sheet(isPresented: $creating) {
      SkillCreationView(store: store, projectPaths: store.skillLibraryProjectPaths, initialProjectPath: store.currentProjectKey) { store.skillLibraryQuery = "" }
    }
  }
}

private struct SkillCreationView: View {
  let store: WorkspaceStore
  let projectPaths: [String]
  @State private var projectPath: String
  let created: () -> Void
  private enum Scope: String, CaseIterable { case personal, project }
  @Environment(\.dismiss) private var dismiss
  @FocusState private var nameFocused: Bool
  @State private var name = ""
  @State private var purpose = ""
  @State private var instructions = ""
  @State private var scope: Scope = .personal
  @State private var error: String?

  init(store: WorkspaceStore, projectPaths: [String], initialProjectPath: String, created: @escaping () -> Void) {
    self.store = store
    self.projectPaths = projectPaths
    self.created = created
    _projectPath = State(initialValue: projectPaths.contains(initialProjectPath)
      ? initialProjectPath : (projectPaths.first ?? ""))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("新建技能").appFont(.title2, weight: .semibold)
      Text(scope == .project
        ? "技能保存在所选项目的 .agents/skills，可在适用项目的任务中调用。"
        : "技能保存在 ShipiOS 的独立目录，并可在任务中通过 $名称 调用。")
        .foregroundStyle(.secondary)
      Form {
        Picker("保存位置", selection: $scope) {
          Text("ShipiOS 私有").tag(Scope.personal)
          if !projectPaths.isEmpty { Text("项目").tag(Scope.project) }
        }
        if scope == .project {
          Picker("项目", selection: $projectPath) {
            ForEach(projectPaths, id: \.self) { path in
              Text(URL(fileURLWithPath: path).lastPathComponent).tag(path).help(path)
            }
          }
        }
        TextField("名称", text: $name, prompt: Text("例如 code-review"))
          .focused($nameFocused)
        TextField("用途描述", text: $purpose, prompt: Text("说明何时使用这个技能"))
        VStack(alignment: .leading, spacing: 8) {
          Text("技能指令")
          TextEditor(text: $instructions)
            .font(.body)
            .frame(minHeight: 190)
            .border(.secondary.opacity(0.3))
        }
      }
      if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
      HStack {
        Spacer()
        Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("创建") {
          let id = name.trimmingCharacters(in: .whitespacesAndNewlines)
          let saved = scope == .project
            ? store.createRepositorySkill(id: id, description: purpose,
                instructions: instructions, projectPath: projectPath)
            : store.createStandaloneSkill(id: id, description: purpose, instructions: instructions)
          if saved {
            created()
            dismiss()
          } else { error = store.pluginsError ?? "无法创建技能。" }
        }.buttonStyle(.borderedProminent)
          .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(24)
    .frame(minWidth: 560, idealWidth: 640, minHeight: 400)
    .onAppear { nameFocused = true }
  }
}
