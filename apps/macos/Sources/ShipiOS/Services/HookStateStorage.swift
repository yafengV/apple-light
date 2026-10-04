import Foundation

/// App-owned decisions are separate from immutable plugin packages and from
/// personal Codex configuration. Writes merge the latest on-disk decisions.
enum HookStateStorage {
  typealias Decisions = [String: [String: HookDecision]]
  static func url(root: URL) -> URL { root.appendingPathComponent("Hooks/state.json") }
  static func load(root: URL) throws -> Decisions {
    let file = url(root: root)
    guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
    try check(file: file, root: root)
    let data = try Data(contentsOf: file)
    guard data.count <= 4 * 1024 * 1024 else { throw AgentFailure(message: "Hook 决策文件过大。") }
    return try JSONDecoder().decode(Decisions.self, from: data)
  }
  static func update(root: URL, sourceID: String, changes: [String: HookDecision]) throws {
    try update(root: root, changes: [sourceID: changes])
  }
  static func update(root: URL, changes: Decisions) throws {
    var all = try load(root: root)
    for (sourceID, entries) in changes {
      var source = all[sourceID] ?? [:]
      for (key, change) in entries {
        var decision = source[key] ?? HookDecision()
        if let enabled = change.enabled { decision.enabled = enabled }
        if let hash = change.trustedHash { decision.trustedHash = hash }
        source[key] = decision
      }
      all[sourceID] = source
    }
    let file = url(root: root)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
      withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try check(file: file, root: root)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    let data = try encoder.encode(all)
    guard data.count <= 4 * 1024 * 1024 else { throw AgentFailure(message: "Hook 决策文件过大。") }
    try data.write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }
  private static func check(file: URL, root: URL) throws {
    let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
    let canonical = file.resolvingSymlinksInPath().standardizedFileURL
    guard canonical.path == canonicalRoot.appendingPathComponent("Hooks/state.json").path else {
      throw AgentFailure(message: "Hook 决策路径无效。")
    }
    if FileManager.default.fileExists(atPath: file.path) {
      let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw AgentFailure(message: "Hook 决策路径无效。")
      }
    }
  }
}
