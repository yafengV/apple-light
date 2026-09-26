import Foundation

@MainActor
extension WorkspaceStore {
  func loadSharedEnvironment() async {
    guard connected, let path = project?.path else { return }
    do {
      let result = try await client.request("environment.load")
      guard project?.path == path else { return }
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
        environmentStatus = "已从项目共享环境文件载入。"
      } else {
        environmentStatus = "项目尚无共享环境文件；保存后可在 Codex 中使用。"
      }
    } catch {
      guard project?.path == path else { return }
      environmentStatus = "共享环境文件读取失败：\(error.localizedDescription)"
    }
  }

  func saveSharedEnvironment() async {
    guard connected, let path = project?.path, !environmentSaving else { return }
    let name = environmentName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      environmentStatus = "请填写环境名称。"
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
    config["actions"] = .array(environmentActions.compactMap { action in
      let title = action.title.trimmingCharacters(in: .whitespacesAndNewlines)
      let script = action.script.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !title.isEmpty, !script.isEmpty else { return nil }
      var fields: [String: JSONValue] = [
        "name": .string(title), "command": .string(script), "icon": .string(action.symbol),
      ]
      if action.platform != .all { fields["platform"] = .string(action.platform.rawValue) }
      return .object(fields)
    })
    do {
      let result = try await client.request("environment.save", [
        "expectedRevision": environmentRevision.map(JSONValue.string) ?? .null,
        "config": .object(config),
      ])
      guard project?.path == path else { return }
      environmentRevision = result["revision"].text
      environmentExists = result["exists"].boolean == true
      environmentStatus = "已保存至项目共享环境文件。"
      saveProfile()
    } catch {
      guard project?.path == path else { return }
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
