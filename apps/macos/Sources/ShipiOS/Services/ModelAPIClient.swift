import Foundation
import Security

/// Credentials are scoped to ShipiOS and the explicitly configured API base URL.
enum ModelKeychain {
  private static let service = "dev.shipios.desktop.model-api"
  static func read(account: String) throws -> String? {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword, kSecAttrService: service,
      kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw AgentFailure(message: "无法读取 ShipiOS Keychain 凭据（\(status)）。")
    }
    return String(data: data, encoding: .utf8)
  }
  static func save(_ key: String, account: String) throws {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
    ]
    let values: [CFString: Any] = [
      kSecValueData: Data(key.utf8),
      kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
    if status == errSecItemNotFound {
      status = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw AgentFailure(message: "无法保存到 Keychain（\(status)）。") }
  }
}

final class ModelTransportDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    // Never forward an API credential to a redirect target.
    completionHandler(nil)
  }
}

struct ModelAPIClient {
  func stream(
    config: ModelConfiguration, key: String?, messages: [ChatMessage], attachmentRoot: URL? = nil,
    onDelta: @escaping @Sendable (String) async -> Void
  ) async throws -> ModelTokenUsage? {
    let result = try await streamTurn(config: config, key: key, messages: messages,
      attachmentRoot: attachmentRoot, onDelta: onDelta)
    guard result.calls.isEmpty else { throw AgentFailure(message: "本次请求未提供可执行工具。") }
    return result.usage
  }

  func streamTurn(
    config: ModelConfiguration, key: String?, messages: [ChatMessage], attachmentRoot: URL? = nil,
    tools: [JSONValue] = [], onDelta: @escaping @Sendable (String) async -> Void
  ) async throws -> ModelTurnResult {
    var request = URLRequest(url: try config.endpoint("chat/completions"))
    request.httpMethod = "POST"
    request.timeoutInterval = 120
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    if let key, !key.isEmpty {
      request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }
    request.httpBody = try await Task.detached(priority: .userInitiated) {
      try ImageAttachmentStorage.requestData(config: config, messages: messages, root: attachmentRoot, tools: tools)
    }.value
    try Task.checkCancellation()
    let session = URLSession(
      configuration: .ephemeral, delegate: ModelTransportDelegate(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw AgentFailure(
        message:
          "模型请求失败，HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)。请检查 API 地址、凭据和模型名称。")
    }
    var total = 0
    var completed = false
    var choiceFinished = false
    var usage: ModelTokenUsage?
    var line = Data()
    var textOutput = ""
    var calls = ModelToolCallAccumulator()
    var finishReason: String?
    for try await byte in bytes {
      try Task.checkCancellation()
      if byte != 10 {
        line.append(byte)
        guard line.count <= 262_144 else { throw AgentFailure(message: "模型返回的数据帧过大。") }
        continue
      }
      let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .newlines)
      line.removeAll(keepingCapacity: true)
      if let delta = try ChatStreamDelta.parse(text) {
        if let reported = delta.usage { usage = reported }
        try calls.append(delta.toolFragments)
        if let reason = delta.finishReason { finishReason = reason }
        total += delta.text.utf8.count
        guard total <= 2_097_152 else { throw AgentFailure(message: "模型输出超过 2 MiB，已停止接收。") }
        if !delta.text.isEmpty { await onDelta(delta.text) }
        textOutput += delta.text
        choiceFinished = choiceFinished || delta.choiceFinished
        if delta.finished {
          completed = true
          break
        }
      }
    }
    guard completed || choiceFinished else {
      throw AgentFailure(message: "模型连接提前结束；已保留收到的内容，可以重试。")
    }
    return ModelTurnResult(text: textOutput, calls: try calls.completed(reason: finishReason), usage: usage)
  }
  func test(config: ModelConfiguration, key: String?) async throws -> Int {
    try await models(config: config, key: key).count
  }
  func models(config: ModelConfiguration, key: String?) async throws -> [String] {
    var request = URLRequest(url: try config.endpoint("models"))
    request.timeoutInterval = 20
    if let key, !key.isEmpty {
      request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }
    let session = URLSession(
      configuration: .ephemeral, delegate: ModelTransportDelegate(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (bytes, response) = try await session.bytes(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw AgentFailure(
        message:
          "连接测试失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）。部分兼容服务不提供 /models，可保存后直接发送消息验证。"
      )
    }
    var data = Data()
    for try await byte in bytes {
      try Task.checkCancellation()
      data.append(byte)
      guard data.count <= 1_048_576 else { throw AgentFailure(message: "模型列表过大。") }
    }
    return try ModelCatalog.decode(data)
  }
}
