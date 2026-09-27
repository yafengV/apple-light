import Foundation

struct PluginHookDeclaration: Equatable {
  let event: String
  let command: String
  let source: String
}

enum PluginHookCatalog {
  static func declarations(pluginID: String, root: URL) throws -> [PluginHookDeclaration] {
    try PluginStorage.validateID(pluginID)
    let package = PluginStorage.packageURL(root: root, id: pluginID).standardizedFileURL
    let selection = try PluginStorage.selectedManifest(in: package)
    let extensionObject = (selection.object["extensions"] as? [String: Any])?["com.openai"] as? [String: Any]
    let configured = extensionObject?["hooks"] ?? selection.legacy?["hooks"]
    let configuredSource = extensionObject?["hooks"] == nil
      ? "./.codex-plugin/plugin.json" : "./plugin.json"
    let sources: [(String, Any)]
    if let configured {
      let entries = configured as? [Any] ?? [configured]
      sources = try entries.map { entry in
        if let path = entry as? String {
          let file = try checkedHookURL(path, inside: package)
          let json = try JSONSerialization.jsonObject(with: checkedData(at: file, inside: package))
          return (path, json)
        }
        return (configuredSource, entry)
      }
    } else {
      let file = package.appendingPathComponent("hooks/hooks.json")
      guard FileManager.default.fileExists(atPath: file.path) else { return [] }
      sources = [("./hooks/hooks.json", try JSONSerialization.jsonObject(
        with: checkedData(at: file, inside: package)))]
    }
    return sources.flatMap { source, json in
      let events = (json as? [String: Any])?["hooks"] as? [String: Any] ?? [:]
      return events.keys.sorted().flatMap { event -> [PluginHookDeclaration] in
        let groups = events[event] as? [[String: Any]] ?? []
        return groups.flatMap { group in
          (group["hooks"] as? [[String: Any]] ?? []).compactMap { hook in
            guard hook["type"] as? String == "command",
              let command = hook["command"] as? String, !command.isEmpty else { return nil }
            return PluginHookDeclaration(event: event, command: command, source: source)
          }
        }
      }
    }
  }

  private static func checkedHookURL(_ path: String, inside package: URL) throws -> URL {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard path.hasPrefix("./"), parts.count > 1,
      parts.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
      throw AgentFailure(message: "Hook 路径必须是插件内的 ./ 相对路径。")
    }
    return package.appendingPathComponent(String(path.dropFirst(2)))
  }

  private static func checkedData(at file: URL, inside package: URL) throws -> Data {
    let realPackage = package.resolvingSymlinksInPath().path
    guard realPackage == package.path,
      file.standardizedFileURL.path.hasPrefix(package.path + "/"),
      file.resolvingSymlinksInPath().path == file.standardizedFileURL.path,
      (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
      throw AgentFailure(message: "Hook 配置必须是已安装插件内的普通文件。")
    }
    let data = try Data(contentsOf: file)
    guard data.count <= PluginStorage.maximumManifestBytes else {
      throw AgentFailure(message: "Hook 配置超过 256 KiB。")
    }
    return data
  }
}
