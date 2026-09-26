import Foundation

struct LocalEnvironmentEntry: Decodable, Identifiable {
  let fileName: String
  let name: String?
  let error: String?
  var id: String { fileName }
  var title: String { name.map { "\($0) · \(fileName)" } ?? fileName }
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
  var currentEnvironmentFormState: LocalEnvironmentFormState {
    LocalEnvironmentFormState(name: environmentName, setup: worktreeSetupScript,
      setupPlatforms: setupPlatformScripts, cleanup: worktreeCleanupScript,
      cleanupPlatforms: cleanupPlatformScripts, actions: environmentActions)
  }

  var environmentHasUnsavedChanges: Bool {
    environmentLoadedState.map { $0 != currentEnvironmentFormState } ?? false
  }

  func refreshSharedEnvironments() async {
    guard connected, let path = project?.path else { return }
    do {
      let entries = try await client.request("environment.list").decode([LocalEnvironmentEntry].self)
      guard project?.path == path else { return }
      environmentFiles = entries
      let valid = entries.filter { $0.error == nil }
      if !valid.contains(where: { $0.fileName == environmentFileName }) {
        environmentFileName = valid.first(where: { $0.fileName == "environment.toml" })?.fileName
          ?? valid.first?.fileName ?? "environment.toml"
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
      environmentStatus = "共享环境文件读取失败：\(error.localizedDescription)"
    }
  }

  func selectSharedEnvironment(_ fileName: String) async {
    guard environmentFiles.contains(where: { $0.fileName == fileName && $0.error == nil }) else { return }
    environmentFileName = fileName
    await loadSharedEnvironment()
    saveProfile()
  }

  func createSharedEnvironment() {
    let occupied = Set(environmentFiles.map(\.fileName))
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

  func saveSharedEnvironment() async {
    guard connected, let path = project?.path, !environmentSaving else { return }
    let name = environmentName.trimmingCharacters(in: .whitespacesAndNewlines)
    let fileName = environmentFileName
    guard !name.isEmpty else {
      environmentStatus = "请填写环境名称。"
      return
    }
    guard environmentActions.allSatisfy(\.isRunnable) else {
      environmentStatus = "请为每个操作填写名称和命令。"
      return
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
      guard project?.path == path, environmentFileName == fileName else { return }
      environmentRevision = result["revision"].text
      environmentExists = result["exists"].boolean == true
      environmentStatus = "已保存至项目共享环境文件。"
      environmentLoadedState = currentEnvironmentFormState
      saveProfile()
      if let entries = try? await client.request("environment.list")
        .decode([LocalEnvironmentEntry].self) {
        environmentFiles = entries
      }
    } catch {
      guard project?.path == path, environmentFileName == fileName else { return }
      environmentStatus = "共享环境保存失败：\(error.localizedDescription)"
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
