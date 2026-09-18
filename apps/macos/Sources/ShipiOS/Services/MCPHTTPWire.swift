import Foundation

private final class MCPRedirectBlocker: NSObject, URLSessionTaskDelegate {
  func urlSession(_ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor final class MCPHTTPWire: MCPWire {
  var protocolVersion: String?
  private let endpoint: URL
  private let headers: [String: String]
  private let session: URLSession
  private var sessionID: String?
  private var closed = false

  init(configuration: MCPServerConfiguration, environment: [String: String] = ProcessInfo.processInfo.environment,
    timeout: TimeInterval = 15) throws {
    let config = try configuration.validated()
    guard let endpoint = URL(string: config.url) else { throw AgentFailure(message: "MCP URL 无效。") }
    self.endpoint = endpoint
    var headers = Dictionary(uniqueKeysWithValues: config.headers.map { ($0.key, $0.value) })
    for entry in config.environmentHeaders {
      guard let value = environment[entry.value] else { throw AgentFailure(message: "缺少环境变量：\(entry.value)") }
      headers[entry.key] = value
    }
    if !config.bearerTokenEnvironmentVariable.isEmpty {
      guard let value = environment[config.bearerTokenEnvironmentVariable], !value.isEmpty else {
        throw AgentFailure(message: "缺少 Bearer token 环境变量：\(config.bearerTokenEnvironmentVariable)")
      }
      headers["Authorization"] = "Bearer " + value
    }
    guard headers.values.allSatisfy({ !$0.utf8.contains(where: { $0 == 0 || $0 == 10 || $0 == 13 }) }) else {
      throw AgentFailure(message: "MCP 请求头的环境变量包含无效字符。")
    }
    self.headers = headers
    let options = URLSessionConfiguration.ephemeral
    options.timeoutIntervalForRequest = timeout
    options.timeoutIntervalForResource = timeout
    options.httpShouldSetCookies = false
    options.urlCache = nil
    self.session = URLSession(configuration: options, delegate: MCPRedirectBlocker(), delegateQueue: nil)
  }

  private func request(method: String) -> URLRequest {
    var request = URLRequest(url: endpoint)
    request.httpMethod = method
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id") }
    if let protocolVersion { request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
    return request
  }

  func send(_ message: JSONValue) async throws -> JSONValue {
    guard !closed else { throw CancellationError() }
    try Task.checkCancellation()
    var request = request(method: "POST")
    request.httpBody = try JSONEncoder().encode(message)
    let (bytes, response) = try await session.bytes(for: request)
    guard let response = response as? HTTPURLResponse else { throw AgentFailure(message: "MCP 返回无效 HTTP 响应。") }
    guard (200..<300).contains(response.statusCode) else {
      let message = [401, 403].contains(response.statusCode) ? "MCP 需要授权，请检查凭据配置。"
        : response.statusCode == 404 ? "MCP 地址或会话已失效，请重新连接。"
        : "MCP HTTP 请求失败（\(response.statusCode)）。"
      throw AgentFailure(message: message)
    }
    if message["method"].text == "initialize", let value = response.value(forHTTPHeaderField: "MCP-Session-Id") {
      guard !value.isEmpty, value.utf8.allSatisfy({ (0x21...0x7e).contains($0) }) else {
        throw AgentFailure(message: "MCP 会话标识无效。")
      }
      sessionID = value
    }
    guard message["id"] != .null, message["method"].text != nil else { return .null }
    let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
    let eventStream = contentType.hasPrefix("text/event-stream")
    guard eventStream || contentType.hasPrefix("application/json") else {
      throw AgentFailure(message: "MCP 返回了不支持的内容类型。")
    }
    var data = Data(), line = Data(), eventLines: [String] = []
    var total = 0
    for try await byte in bytes {
      try Task.checkCancellation()
      total += 1
      guard total <= 4_194_304 else { throw AgentFailure(message: "MCP 响应超过 4 MiB。") }
      if !eventStream { data.append(byte); continue }
      if byte != 10 { line.append(byte); continue }
      if line.last == 13 { line.removeLast() }
      guard let text = String(data: line, encoding: .utf8) else { throw AgentFailure(message: "MCP 事件编码无效。") }
      line.removeAll(keepingCapacity: true)
      if text.isEmpty {
        if !eventLines.isEmpty {
          let payload = eventLines.joined(separator: "\n")
          eventLines.removeAll()
          guard !payload.isEmpty else { continue }
          let frame = try JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8))
          if frame["method"].text != nil, frame["id"] != .null {
            _ = try await send(MCPMessages.reply(to: frame))
          } else if frame["id"] == message["id"] { return frame }
        }
      } else if text.hasPrefix("data:") {
        let value = String(text.dropFirst(5))
        eventLines.append(value.hasPrefix(" ") ? String(value.dropFirst()) : value)
      }
    }
    guard !eventStream else { throw AgentFailure(message: "MCP 事件流在返回结果前结束，请重试。") }
    return try JSONDecoder().decode(JSONValue.self, from: data)
  }

  func close() async {
    guard !closed else { return }
    closed = true
    if sessionID != nil {
      var deletion = request(method: "DELETE")
      deletion.timeoutInterval = 2
      _ = try? await session.data(for: deletion)
    }
    session.invalidateAndCancel()
  }
}
