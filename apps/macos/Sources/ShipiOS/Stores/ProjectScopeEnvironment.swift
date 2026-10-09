import Foundation

/// Metadata is prepared against the new Agent without exposing a partial scope.
struct ProjectScopeEnvironment {
  var files: [LocalEnvironmentEntry] = []
  var fileName: String
  var form: LocalEnvironmentFormState
  var revision: String?
  var exists = false
  var status = ""
  var loadedForm = false
  var savesProfile = false

  @MainActor static func load(client: AgentClient, fileName: String,
    form: LocalEnvironmentFormState) async -> Self {
    var prepared = Self(fileName: fileName, form: form)
    do {
      prepared.files = try await client.request("environment.list").decode([LocalEnvironmentEntry].self)
    } catch {
      prepared.status = "环境目录读取失败：\(error.localizedDescription)"
      return prepared
    }
    let valid = prepared.files.filter { $0.error == nil }
    if !valid.contains(where: { $0.id == prepared.fileName }) {
      prepared.fileName = valid.first(where: { !$0.inherited && $0.fileName == "environment.toml" })?.id
        ?? valid.first(where: { $0.fileName == "environment.toml" })?.id
        ?? valid.first?.id ?? "environment.toml"
    }
    do {
      let loaded = try await client.request("environment.load", ["fileName": .string(prepared.fileName)])
      prepared.exists = loaded["exists"].boolean == true
      prepared.revision = loaded["revision"].text
      if prepared.exists {
        if loaded["error"].text != nil {
          prepared.clearForm()
          prepared.status = "环境文件无法解析。编辑并保存可替换该文件。"
        } else {
          prepared.form = .init(config: loaded["config"], fallbackName: prepared.form.name)
          prepared.status = "已载入 \(prepared.fileName)。"
          prepared.savesProfile = true
        }
      } else {
        prepared.status = "\(prepared.fileName) 尚未创建；保存后可在 Codex 中使用。"
      }
    } catch {
      prepared.clearForm()
      prepared.status = "共享环境文件读取失败：\(error.localizedDescription)"
    }
    prepared.loadedForm = true
    return prepared
  }

  private mutating func clearForm() {
    form = .init(name: URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent,
      setup: "", setupPlatforms: .init(), cleanup: "", cleanupPlatforms: .init(), actions: [])
  }
}

extension WorkspaceStore {
  func prepareProjectScopeEnvironment(_ root: URL) async -> ProjectScopeEnvironment {
    let profile = library.profiles[root.path] ?? BuildProfile()
    var form = LocalEnvironmentFormState(name: library.projectTitle(root.path),
      setup: profile.worktreeSetupScript, setupPlatforms: profile.setupPlatformScripts,
      cleanup: profile.worktreeCleanupScript, cleanupPlatforms: profile.cleanupPlatformScripts, actions: profile.actions)
    if let environment = library.managedWorktrees.first(where: { $0.path == root.path })?.environment {
      form.name = environment.name
      return .init(fileName: environment.fileName ?? "environment.toml", form: form,
        status: environment.disabled ? "此任务创建时选择了无环境。" : "此任务使用创建时保存的环境配置。", loadedForm: true)
    }
    return await .load(client: client, fileName: profile.environmentFileName ?? "environment.toml", form: form)
  }

  func applyProjectScopeEnvironment(_ prepared: ProjectScopeEnvironment) {
    environmentFiles = prepared.files; environmentFileName = prepared.fileName
    environmentName = prepared.form.name
    worktreeSetupScript = prepared.form.setup; setupPlatformScripts = prepared.form.setupPlatforms
    worktreeCleanupScript = prepared.form.cleanup; cleanupPlatformScripts = prepared.form.cleanupPlatforms
    environmentActions = prepared.form.actions
    environmentRevision = prepared.revision; environmentExists = prepared.exists; environmentStatus = prepared.status
    environmentLoadedState = prepared.loadedForm ? currentEnvironmentFormState : nil
    if prepared.savesProfile { saveProfile() }
  }
}
