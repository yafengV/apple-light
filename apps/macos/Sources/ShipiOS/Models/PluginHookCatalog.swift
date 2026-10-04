import Foundation
import CryptoKit

struct PluginHookDeclaration: Equatable {
  let event: String
  let kind: String
  let detail: String
  let source: String
  let matcher: String?
  let statusMessage: String?
  let timeout: Int?

  var availability: String {
    let events: Set<String> = ["PreToolUse", "PermissionRequest", "PostToolUse", "PreCompact",
      "PostCompact", "SessionStart", "SessionEnd", "UserPromptSubmit", "SubagentStart",
      "SubagentStop", "Stop", "Interrupt"]
    guard events.contains(event) else { return "未知事件，Codex 会忽略" }
    return switch kind {
    case "command": detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "空命令，Codex 会跳过" : "未授权执行"
    case "mcp_tool": detail == "服务器或工具未填写" ? "服务器或工具缺失，Codex 会跳过"
      : (event == "SessionEnd" ? "此事件不支持 MCP Hook" : "未授权执行")
    case "prompt", "agent": "当前 Codex Core 不支持此类型"
    default: "未知 Hook 类型"
    }
  }
}

enum PluginHookCatalog {
  private static func configurations(pluginID: String, root: URL) throws -> [(String, Any)] {
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
    return sources
  }

  static func declarations(pluginID: String, root: URL) throws -> [PluginHookDeclaration] {
    let sources = try configurations(pluginID: pluginID, root: root)
    return try declarations(sources: sources)
  }

  private static func declarations(sources: [(String, Any)]) throws -> [PluginHookDeclaration] {
    var declarations: [PluginHookDeclaration] = []
    for (source, json) in sources {
      guard let file = json as? [String: Any] else {
        throw AgentFailure(message: "Hook 配置 \(source) 必须是对象。")
      }
      guard file["hooks"] == nil || file["hooks"] is [String: Any] else {
        throw AgentFailure(message: "Hook 配置 \(source) 的 hooks 字段无效。")
      }
      let events = file["hooks"] as? [String: Any] ?? [:]
      for event in events.keys.sorted() {
        guard let groups = events[event] as? [[String: Any]] else {
          throw AgentFailure(message: "Hook 事件 \(event) 的声明无效。")
        }
        for group in groups {
          guard group["hooks"] == nil || group["hooks"] is [[String: Any]] else {
            throw AgentFailure(message: "Hook 事件 \(event) 的处理器列表无效。")
          }
          let handlers = group["hooks"] as? [[String: Any]] ?? []
          for hook in handlers {
            guard let kind = hook["type"] as? String else {
              throw AgentFailure(message: "Hook 事件 \(event) 缺少类型。")
            }
            let detail: String
            switch kind {
            case "command": detail = hook["command"] as? String ?? ""
            case "mcp_tool":
              let server = hook["server"] as? String ?? ""
              let tool = hook["tool"] as? String ?? ""
              detail = server.isEmpty || tool.isEmpty ? "服务器或工具未填写" : "\(server).\(tool)"
            default: detail = ""
            }
            declarations.append(PluginHookDeclaration(
              event: event, kind: kind, detail: detail, source: source,
              matcher: group["matcher"] as? String,
              statusMessage: hook["statusMessage"] as? String,
              timeout: hook["timeout"] as? Int))
          }
        }
      }
    }
    return declarations
  }

  static func sources(plugin: PluginInstallation, root: URL,
    decisions: HookStateStorage.Decisions) throws -> [HookSettingsSource] {
    let package = PluginStorage.packageURL(root: root, id: plugin.id).standardizedFileURL
    var occurrences: [String: Int] = [:]
    let configurations = try configurations(pluginID: plugin.id, root: root)
    _ = try declarations(sources: configurations)
    return try configurations.map { label, object in
      let index = occurrences[label, default: 0]
      occurrences[label] = index + 1
      // Source identity follows the package and declared location, rather than
      // definition contents, so edits become modified instead of losing history.
      let identity = plugin.id + "\n" + label + "\n" + String(index)
      let id = "plugin_" + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
      let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
      guard data.count <= PluginStorage.maximumManifestBytes,
        let configuration = String(data: data, encoding: .utf8) else {
        throw AgentFailure(message: "Hook 配置超过 256 KiB。")
      }
      let file = try checkedHookURL(label, inside: package)
      return HookSettingsSource(id: id, pluginID: plugin.id, name: plugin.name,
        label: label, fileURL: file, pluginEnabled: plugin.enabled,
        binding: HookSourceBinding(id: id, configuration: configuration, states: decisions[id] ?? [:]))
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
