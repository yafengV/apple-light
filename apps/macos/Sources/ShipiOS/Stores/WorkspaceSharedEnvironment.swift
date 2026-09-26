import Foundation

struct LocalEnvironmentEntry: Decodable, Identifiable {
  let id: String
  let fileName: String
  let name: String?
  let error: String?
  let inherited: Bool
  let sourceFolder: String
  var title: String {
    let label = name.map { "\($0) · \(fileName)" } ?? fileName
    return inherited ? "\(label) — 来自 \(sourceFolder)" : label
  }
}

enum WorktreeEnvironmentChoice {
  static let none = "__none__"
  static let legacy = "__legacy__"
}

struct LocalEnvironmentFormState: Equatable {
  var name: String
  var setup: String
  var setupPlatforms: EnvironmentPlatformScripts
  var cleanup: String
  var cleanupPlatforms: EnvironmentPlatformScripts
  var actions: [EnvironmentAction]
}

@MainActor
extension WorkspaceStore {
  func refreshEnvironmentCatalog() async {
    guard !environmentCatalogLoading else { return }
    let paths = library.orderedProjects
    let request = UUID()
    environmentCatalogRequest = request
    environmentCatalog = [:]
    environmentCatalogErrors = [:]
    guard !paths.isEmpty else { environmentCatalogLoading = false; return }
    environmentCatalogLoading = true
    let browser = AgentClient()
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("shipios-environment-catalog-\(UUID())", isDirectory: true)
    do {
      guard let seed = paths.first(where: { path in
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
          && isDirectory.boolValue
      }) else { throw AgentFailure(message: "没有可读取的项目目录。") }
      try browser.start(executable: executable, project: URL(fileURLWithPath: seed),
        dataDirectory: temporary)
      _ = try await browser.request("initialize", ["protocolVersion": .number(1)])
      for path in paths {
        guard environmentCatalogRequest == request else { break }
        do {
          let result = try await browser.request("environment.list", ["projectPath": .string(path)])
          let entries = try result.decode([LocalEnvironmentEntry].self)
          if environmentCatalogRequest == request { environmentCatalog[path] = entries }
        } catch {
          if environmentCatalogRequest == request {
            environmentCatalogErrors[path] = error.localizedDescription
          }
        }
      }
    } catch {
      if environmentCatalogRequest == request {
        for path in paths where environmentCatalog[path] == nil {
          environmentCatalogErrors[path] = error.localizedDescription
        }
      }
    }
    await browser.stop()
    try? FileManager.default.removeItem(at: temporary)
    if environmentCatalogRequest == request { environmentCatalogLoading = false }
  }

  func managedEnvironmentSnapshot(selectionID: String) async throws -> ManagedEnvironmentSnapshot {
    guard connected, let project else { throw AgentFailure(message: "项目环境尚未连接。") }
    if selectionID == WorktreeEnvironmentChoice.none { return .none }
    if selectionID == WorktreeEnvironmentChoice.legacy {
      let profile = library.profiles[project.path] ?? BuildProfile()
      return ManagedEnvironmentSnapshot(fileName: nil, name: "ShipiOS 本地配置", disabled: false,
        setupScript: profile.worktreeSetupScript, setupPlatforms: profile.setupPlatformScripts,
        cleanupScript: profile.worktreeCleanupScript, cleanupPlatforms: profile.cleanupPlatformScripts,
        actions: profile.actions)
    }
    guard environmentFiles.contains(where: { $0.id == selectionID && $0.error == nil }) else {
      throw AgentFailure(message: "所选本地环境已不可用，请刷新环境列表后重试。")
    }
    let loaded = try await client.request("environment.load", ["fileName": .string(selectionID)])
    guard loaded["exists"].boolean == true else {
      throw AgentFailure(message: "所选本地环境文件已被删除，请刷新后重试。")
    }
    let config = loaded["config"]
    let actions = config["actions"].items.map { action in
      EnvironmentAction(title: action["name"].text ?? "",
        symbol: action["icon"].text ?? "tool", script: action["command"].text ?? "",
        platform: EnvironmentPlatform(rawValue: action["platform"].text ?? "all") ?? .all)
    }
    return ManagedEnvironmentSnapshot(fileName: selectionID,
      name: config["name"].text ?? selectionID, disabled: false,
      setupScript: config["setup"]["script"].text ?? "",
      setupPlatforms: platformScripts(from: config["setup"]),
      cleanupScript: config["cleanup"]["script"].text ?? "",
      cleanupPlatforms: platformScripts(from: config["cleanup"]), actions: actions)
  }

  var currentEnvironmentFormState: LocalEnvironmentFormState {
    LocalEnvironmentFormState(name: environmentName, setup: worktreeSetupScript,
      setupPlatforms: setupPlatformScripts, cleanup: worktreeCleanupScript,
      cleanupPlatforms: cleanupPlatformScripts, actions: environmentActions)
  }

  var environmentHasUnsavedChanges: Bool {
    environmentLoadedState.map { $0 != currentEnvironmentFormState } ?? false
  }

  private func clearEnvironmentForm(for fileName: String) {
    environmentName = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
    worktreeSetupScript = ""
    setupPlatformScripts = .init()
    worktreeCleanupScript = ""
    cleanupPlatformScripts = .init()
    environmentActions = []
    environmentLoadedState = currentEnvironmentFormState
  }

  func refreshSharedEnvironments() async {
    guard connected, let path = project?.path else { return }
    do {
      let entries = try await client.request("environment.list").decode([LocalEnvironmentEntry].self)
      guard project?.path == path else { return }
      environmentFiles = entries
      let valid = entries.filter { $0.error == nil }
      if !valid.contains(where: { $0.id == environmentFileName }) {
        environmentFileName = valid.first(where: { !$0.inherited && $0.fileName == "environment.toml" })?.id
          ?? valid.first(where: { $0.fileName == "environment.toml" })?.id
          ?? valid.first?.id ?? "environment.toml"
      }
      await loadSharedEnvironment()
    } catch {
      guard project?.path == path else { return }
      environmentStatus = "环境目录读取失败：\(error.localizedDescription)"
    }
  }

  func loadSharedEnvironment() async {
    guard connected, let path = project?.path else { return }
    let fileName = environmentFileName
    environmentRevision = nil
    environmentExists = false
    do {
      let result = try await client.request("environment.load", ["fileName": .string(fileName)])
      guard project?.path == path, environmentFileName == fileName else { return }
      environmentExists = result["exists"].boolean == true
      environmentRevision = result["revision"].text
      if environmentExists {
        if result["error"].text != nil {
          clearEnvironmentForm(for: fileName)
          environmentStatus = "环境文件无法解析。编辑并保存可替换该文件。"
          return
        }
        let config = result["config"]
        environmentName = config["name"].text ?? environmentName
        worktreeSetupScript = config["setup"]["script"].text ?? ""
        setupPlatformScripts = platformScripts(from: config["setup"])
        worktreeCleanupScript = config["cleanup"]["script"].text ?? ""
        cleanupPlatformScripts = platformScripts(from: config["cleanup"])
        environmentActions = config["actions"].items.map { action in
          EnvironmentAction(
            title: action["name"].text ?? "", symbol: action["icon"].text ?? "tool",
            script: action["command"].text ?? "",
            platform: EnvironmentPlatform(rawValue: action["platform"].text ?? "all") ?? .all)
        }
        saveProfile()
        environmentStatus = "已载入 \(fileName)。"
      } else {
        environmentStatus = "\(fileName) 尚未创建；保存后可在 Codex 中使用。"
      }
      environmentLoadedState = currentEnvironmentFormState
    } catch {
      guard project?.path == path, environmentFileName == fileName else { return }
      clearEnvironmentForm(for: fileName)
      environmentStatus = "共享环境文件读取失败：\(error.localizedDescription)"
    }
  }

  func selectSharedEnvironment(_ fileName: String) async {
    guard let entry = environmentFiles.first(where: { $0.id == fileName }) else { return }
    environmentFileName = fileName
    await loadSharedEnvironment()
    if entry.error == nil { saveProfile() }
  }

  func createSharedEnvironment() {
    let occupied = Set(environmentFiles.filter { !$0.inherited }.map(\.fileName))
    let next: String
    if !occupied.contains("environment.toml") { next = "environment.toml" }
    else {
      var number = 2
      while occupied.contains("environment-\(number).toml") { number += 1 }
      next = "environment-\(number).toml"
    }
    environmentFileName = next
    environmentName = project.map { library.projectTitle($0.path) } ?? ""
    worktreeSetupScript = ""
    setupPlatformScripts = .init()
    worktreeCleanupScript = ""
    cleanupPlatformScripts = .init()
    environmentActions = []
    environmentExists = false
    environmentRevision = nil
    environmentStatus = "新环境 \(next) 尚未保存。"
    environmentLoadedState = currentEnvironmentFormState
    saveProfile()
  }

  @discardableResult func saveSharedEnvironment() async -> Bool {
    guard connected, let path = project?.path, !environmentSaving else { return false }
    let name = environmentName.trimmingCharacters(in: .whitespacesAndNewlines)
    let fileName = environmentFileName
    guard !name.isEmpty else {
      environmentStatus = "请填写环境名称。"
      return false
    }
    guard environmentActions.allSatisfy(\.isRunnable) else {
      environmentStatus = "请为每个操作填写名称和命令。"
      return false
    }
    environmentSaving = true
    defer { environmentSaving = false }
    var config: [String: JSONValue] = [
      "version": .number(1), "name": .string(name),
      "setup": .object(platformScripts(worktreeSetupScript, setupPlatformScripts)),
    ]
    let cleanup = platformScripts(worktreeCleanupScript, cleanupPlatformScripts)
    if !worktreeCleanupScript.isEmpty || cleanupPlatformScripts != .init() {
      config["cleanup"] = .object(cleanup)
    }
    config["actions"] = .array(environmentActions.map { action in
      let title = action.title.trimmingCharacters(in: .whitespacesAndNewlines)
      let script = action.script.trimmingCharacters(in: .whitespacesAndNewlines)
      var fields: [String: JSONValue] = [
        "name": .string(title), "command": .string(script), "icon": .string(action.symbol),
      ]
      if action.platform != .all { fields["platform"] = .string(action.platform.rawValue) }
      return .object(fields)
    })
    do {
      let result = try await client.request("environment.save", [
        "fileName": .string(fileName),
        "expectedRevision": environmentRevision.map(JSONValue.string) ?? .null,
        "config": .object(config),
      ])
      guard project?.path == path, environmentFileName == fileName else { return false }
      environmentRevision = result["revision"].text
      environmentExists = result["exists"].boolean == true
      environmentStatus = "已保存至项目共享环境文件。"
      environmentLoadedState = currentEnvironmentFormState
      saveProfile()
      if let entries = try? await client.request("environment.list")
        .decode([LocalEnvironmentEntry].self) {
        if project?.path == path, environmentFileName == fileName { environmentFiles = entries }
      }
      return project?.path == path && environmentFileName == fileName
    } catch {
      guard project?.path == path, environmentFileName == fileName else { return false }
      environmentStatus = "共享环境保存失败：\(error.localizedDescription)"
      return false
    }
  }
}

private func platformScripts(from value: JSONValue) -> EnvironmentPlatformScripts {
  EnvironmentPlatformScripts(
    darwin: value["darwin"]["script"].text ?? "",
    linux: value["linux"]["script"].text ?? "",
    win32: value["win32"]["script"].text ?? "")
}

private func platformScripts(_ script: String, _ overrides: EnvironmentPlatformScripts)
  -> [String: JSONValue]
{
  var fields: [String: JSONValue] = ["script": .string(script)]
  if !overrides.darwin.isEmpty { fields["darwin"] = .object(["script": .string(overrides.darwin)]) }
  if !overrides.linux.isEmpty { fields["linux"] = .object(["script": .string(overrides.linux)]) }
  if !overrides.win32.isEmpty { fields["win32"] = .object(["script": .string(overrides.win32)]) }
  return fields
}
