import Foundation

enum HookStaging {
  struct Attachment {
    let url: URL
    let id: UUID
    let byteCount: Int
    var wireValue: JSONValue { .object([
      "id": .string(id.uuidString), "byteCount": .number(Double(byteCount))]) }
    func remove() { try? FileManager.default.removeItem(at: url) }
  }
  static func stage(_ sources: [HookSourceBinding], root: URL) throws -> Attachment {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(sources)
    guard data.count <= 8 * 1024 * 1024 else { throw AgentFailure(message: "Hook 配置总量过大。") }
    let directory = root.appendingPathComponent("HookStaging", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    guard directory.resolvingSymlinksInPath().standardizedFileURL.path
      == root.resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent("HookStaging").path else {
      throw AgentFailure(message: "Hook 临时目录无效。")
    }
    let id = UUID(), url = directory.appendingPathComponent(id.uuidString + ".json")
    do {
      try data.write(to: url, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    } catch { try? FileManager.default.removeItem(at: url); throw error }
    return Attachment(url: url, id: id, byteCount: data.count)
  }
}

@MainActor enum HookInventoryService {
  static func inspect(_ sources: [HookSourceBinding], root: URL, executable: URL) async throws -> HookInventory {
    try Task.checkCancellation()
    let workspace = root.appendingPathComponent("Hooks/InspectionWorkspace", isDirectory: true)
    let directory = root.appendingPathComponent("Projects/HookInventory", isDirectory: true)
    for url in [workspace, directory] {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    }
    let attachment = try HookStaging.stage(sources, root: root)
    defer { attachment.remove() }
    let client = AgentClient()
    do {
      try client.start(executable: executable, project: workspace, dataDirectory: directory)
      _ = try await client.request("initialize", ["protocolVersion": .number(1)], cancelOnTaskCancellation: true)
      let result = try await client.request("codex.hooks.list",
        ["sourcesAttachment": attachment.wireValue], cancelOnTaskCancellation: true)
      let inventory = try result.decode(HookInventory.self)
      await client.stop()
      try Task.checkCancellation()
      return inventory
    } catch {
      await Task { await client.stop(waitForEOF: !Task.isCancelled) }.value
      throw error
    }
  }
}
