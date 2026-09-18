import Foundation

@MainActor final class MCPStdioWire: MCPWire {
  var protocolVersion: String?
  var onDisconnect: ((String) -> Void)?
  var onToolsChanged: (() -> Void)?
  private var process: Process?
  private var input: FileHandle?
  private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
  private var buffer = Data()
  private let timeout: Duration
  private var closed = false

  init(configuration: MCPServerConfiguration, environment: [String: String] = ProcessInfo.processInfo.environment,
    timeout: Duration = .seconds(15)) throws {
    self.timeout = timeout
    let config = try configuration.validated()
    let child = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    child.executableURL = config.command.contains("/")
      ? URL(fileURLWithPath: (config.command as NSString).expandingTildeInPath)
      : URL(fileURLWithPath: "/usr/bin/env")
    child.arguments = (config.command.contains("/") ? [] : [config.command]) + config.arguments
    var variables = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
      "HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory(), "LANG": "en_US.UTF-8"]
    for key in config.environmentPassthrough {
      guard let value = environment[key] else { throw AgentFailure(message: "缺少透传环境变量：\(key)") }
      variables[key] = value
    }
    for entry in config.environment { variables[entry.key] = entry.value }
    child.environment = variables
    if !config.workingDirectory.isEmpty {
      child.currentDirectoryURL = URL(fileURLWithPath: (config.workingDirectory as NSString).expandingTildeInPath)
    }
    child.standardInput = stdin; child.standardOutput = stdout; child.standardError = stderr
    child.terminationHandler = { [weak self] child in
      Task { @MainActor in self?.failed("MCP 进程已退出（\(child.terminationStatus)）。") }
    }
    try child.run()
    process = child; input = stdin.fileHandleForWriting
    let (stream, continuation) = AsyncStream<Data>.makeStream()
    DispatchQueue.global(qos: .userInitiated).async {
      while true {
        let data = stdout.fileHandleForReading.availableData
        if data.isEmpty { break }
        continuation.yield(data)
      }
      continuation.finish()
    }
    Task { [weak self] in
      for await data in stream { self?.receive(data) }
    }
    // Drain server diagnostics without logging potentially sensitive environment values.
    DispatchQueue.global(qos: .utility).async {
      while !stderr.fileHandleForReading.availableData.isEmpty {}
    }
  }

  func send(_ message: JSONValue) async throws -> JSONValue {
    try Task.checkCancellation()
    guard !closed, process?.isRunning == true else { throw AgentFailure(message: "MCP 未连接。") }
    guard let id = message["id"].int, message["method"].text != nil else {
      try write(message)
      return .null
    }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        pending[id] = continuation
        do { try write(message) } catch { pending.removeValue(forKey: id)?.resume(throwing: error) }
        Task { [weak self, timeout] in
          try? await Task.sleep(for: timeout)
          self?.pending.removeValue(forKey: id)?.resume(throwing: AgentFailure(message: "MCP 请求超时。"))
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
      }
    }
  }

  private func write(_ message: JSONValue) throws {
    guard let input else { throw AgentFailure(message: "MCP 输入已关闭。") }
    var data = try JSONEncoder().encode(message)
    guard data.count <= 1_048_576 else { throw AgentFailure(message: "MCP 消息过大。") }
    data.append(10)
    try input.write(contentsOf: data)
  }

  private func receive(_ data: Data) {
    guard !closed else { return }
    buffer.append(data)
    do {
      while let newline = buffer.firstIndex(of: 10) {
        let line = Data(buffer[..<newline])
        buffer.removeSubrange(...newline)
        guard line.count <= 1_048_576 else { throw AgentFailure(message: "MCP 消息过大。") }
        let message = try JSONDecoder().decode(JSONValue.self, from: line)
        guard message["jsonrpc"].text == "2.0" else { throw AgentFailure(message: "MCP 消息格式无效。") }
        if let method = message["method"].text {
          if message["id"] != .null { try write(MCPMessages.reply(to: message)) }
          else if method == "notifications/tools/list_changed" { onToolsChanged?() }
        } else if let id = message["id"].int {
          pending.removeValue(forKey: id)?.resume(returning: message)
        }
      }
      guard buffer.count <= 1_048_576 else { throw AgentFailure(message: "MCP 消息过大。") }
    } catch {
      failed("MCP 返回了无效的 JSON-RPC 消息。")
      Task { await close() }
    }
  }

  private func failed(_ message: String) {
    guard !closed else { return }
    let continuations = Array(pending.values); pending.removeAll()
    for item in continuations { item.resume(throwing: AgentFailure(message: message)) }
    onDisconnect?(message)
  }

  func close() async {
    guard !closed else { return }
    closed = true
    let continuations = Array(pending.values); pending.removeAll()
    for item in continuations { item.resume(throwing: CancellationError()) }
    try? input?.close(); input = nil
    guard let child = process else { return }
    process = nil
    for _ in 0..<10 {
      if !child.isRunning { return }
      try? await Task.sleep(for: .milliseconds(50))
    }
    if child.isRunning { child.terminate() }
    for _ in 0..<10 {
      if !child.isRunning { return }
      try? await Task.sleep(for: .milliseconds(50))
    }
    if child.isRunning { kill(child.processIdentifier, SIGKILL) }
  }
}
