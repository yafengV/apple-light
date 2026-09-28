import Foundation
import Yams

struct SkillInterfaceMetadata: Equatable {
  var displayName: String?
  var shortDescription: String?
  var defaultPrompt: String?
  var iconSmallURL: URL?
  var iconLargeURL: URL?
  var brandColor: String?
  var allowImplicitInvocation = true
  var toolDependencies: [SkillToolDependency] = []
}

extension PluginStorage {
  private struct SkillAgentMetadata: Decodable {
    struct Interface: Decodable {
      var displayName: String?
      var shortDescription: String?
      var defaultPrompt: String?
      var iconSmall: String?
      var iconLarge: String?
      var brandColor: String?
      enum CodingKeys: String, CodingKey {
        case displayName = "display_name", shortDescription = "short_description"
        case defaultPrompt = "default_prompt", iconSmall = "icon_small", iconLarge = "icon_large"
        case brandColor = "brand_color"
      }
    }
    struct Policy: Decodable {
      var allowImplicitInvocation: Bool?
      enum CodingKeys: String, CodingKey { case allowImplicitInvocation = "allow_implicit_invocation" }
    }
    var interface: Interface?
    var policy: Policy?
    struct Dependencies: Decodable { var tools: [SkillToolDependency]? }
    var dependencies: Dependencies?
  }

  static func skillInterface(in folder: URL) throws -> SkillInterfaceMetadata {
    let file = folder.appendingPathComponent("agents/openai.yaml")
    guard FileManager.default.fileExists(atPath: file.path) else { return SkillInterfaceMetadata() }
    let canonical = folder.resolvingSymlinksInPath()
    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      let size = values.fileSize, size <= 65_536,
      file.resolvingSymlinksInPath().path == canonical.appendingPathComponent("agents/openai.yaml").path else {
      throw AgentFailure(message: "技能界面配置必须是技能目录内的普通文件，且不能超过 64 KiB。")
    }
    let data = try Data(contentsOf: file)
    guard let text = String(data: data, encoding: .utf8) else {
      throw AgentFailure(message: "技能界面配置必须使用 UTF-8。")
    }
    let decoded: SkillAgentMetadata
    do { decoded = try YAMLDecoder().decode(SkillAgentMetadata.self, from: text) }
    catch { throw AgentFailure(message: "无法读取技能界面配置：\(error.localizedDescription)") }
    var result = SkillInterfaceMetadata()
    if let interface = decoded.interface {
      result.displayName = nonempty(interface.displayName).map { String($0.prefix(120)) }
      result.shortDescription = nonempty(interface.shortDescription).map { String($0.prefix(500)) }
      result.defaultPrompt = nonempty(interface.defaultPrompt)
      result.iconSmallURL = try skillIcon(interface.iconSmall, in: folder)
      result.iconLargeURL = try skillIcon(interface.iconLarge, in: folder)
      if let color = nonempty(interface.brandColor),
        color.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil {
        result.brandColor = color
      }
    }
    result.allowImplicitInvocation = decoded.policy?.allowImplicitInvocation ?? true
    result.toolDependencies = decoded.dependencies?.tools ?? []
    guard result.toolDependencies.count <= 100 else {
      throw AgentFailure(message: "单个技能最多声明 100 项工具依赖。")
    }
    return result
  }

  private static func nonempty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    return value
  }

  private static func skillIcon(_ path: String?, in folder: URL) throws -> URL? {
    guard let path = nonempty(path) else { return nil }
    let file = folder.appendingPathComponent(path).standardizedFileURL
    let root = folder.standardizedFileURL
    guard !path.hasPrefix("/"), !path.contains("://"), file.path.hasPrefix(root.path + "/"),
      file.resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path
        + String(file.path.dropFirst(root.path.count)) else {
      throw AgentFailure(message: "技能图标必须位于技能目录内。")
    }
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      let size = values.fileSize, size <= 5_242_880 else {
      throw AgentFailure(message: "技能图标必须是普通文件，且不能超过 5 MiB。")
    }
    return file
  }

  static func skillIconData(at file: URL, in folder: URL) throws -> Data {
    let root = folder.standardizedFileURL
    let file = file.standardizedFileURL
    guard file.path.hasPrefix(root.path + "/"),
      file.resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path
        + String(file.path.dropFirst(root.path.count)) else {
      throw AgentFailure(message: "技能图标必须位于技能目录内。")
    }
    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      let size = values.fileSize, size <= 5_242_880 else {
      throw AgentFailure(message: "技能图标文件不可用。")
    }
    return try Data(contentsOf: file)
  }
}
