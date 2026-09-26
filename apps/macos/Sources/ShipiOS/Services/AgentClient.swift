import Foundation

@MainActor
final class AgentClient {
  var onEvent: ((AgentEvent) -> Void)?
  var onCodexEvent: ((JSONValue) -> Void)?
  var onCodexGap: (() -> Void)?
  var onDisconnect: ((String) -> Void)?
  var onGap: (() -> Void)?
  private var process: Process?
  private var input: FileHandle?
  private var nextID = 1
  private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
  private var generation = UUID()
  private var decoder = FrameDecoder()
  private var stopping = false
  private(set) var stderrTail = ""

  func start(executable: URL, project: URL, dataDirectory: URL) throws {
    guard process == nil else { throw AgentFailure(message: "Agent 仍在运行") }
    let child = Process()
    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    child.executableURL = executable
    child.arguments = ["--project", project.path, "--data-dir", dataDirectory.path, "serve"]
    // The GUI does not forward Codex settings, model keys, proxy settings or shell initialization.
    child.environment = [
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(),
      "TMPDIR": NSTemporaryDirectory(), "LANG": "en_US.UTF-8",
      "CODEX_HOME": dataDirectory.appendingPathComponent("Codex").path,
    ]
    child.standardInput = stdin
    child.standardOutput = stdout
    child.standardError = stderr
    generation = UUID()
    let token = generation
    stopping = false
    stderrTail = ""
    decoder = FrameDecoder()
    child.terminationHandler = { [weak self] child in
      Task { @MainActor in self?.terminated(status: child.terminationStatus, token: token) }
    }
    try child.run()
    process = child
    input = stdin.fileHandleForWriting
    // Dedicated readers prevent Foundation pipe buffering from blocking the main actor.
    // One AsyncStream consumer preserves byte order even when several reads arrive together.
    let (outputStream, outputContinuation) = AsyncStream<Data>.makeStream()
    DispatchQueue.global(qos: .userInitiated).async {
      while true {
        let bytes = stdout.fileHandleForReading.availableData
        if bytes.isEmpty { break }
        outputContinuation.yield(bytes)
      }
      outputContinuation.finish()
    }
    Task { [weak self] in
      for await bytes in outputStream { self?.receive(bytes, token: token) }
    }
    DispatchQueue.global(qos: .utility).async { [weak self] in
      while true {
        let bytes = stderr.fileHandleForReading.availableData
        if bytes.isEmpty { break }
        let text = String(decoding: bytes, as: UTF8.self)
        Task { @MainActor in
          guard let self, self.generation == token else { return }
          self.stderrTail = String((self.stderrTail + text).suffix(4000))
        }
      }
    }
  }

  func request(_ method: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
    guard let input, process?.isRunning == true, !stopping else {
      throw AgentFailure(message: "Agent 未连接")
    }
    let id = nextID
    nextID += 1
    let frame = JSONValue.object([
      "jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method),
      "params": .object(params),
    ])
    var bytes = try JSONEncoder().encode(frame)
    bytes.append(10)
    guard bytes.count <= 65536 else { throw AgentFailure(message: "请求超过 64 KiB") }
    let token = generation
    return try await withCheckedThrowingContinuation { continuation in
      pending[id] = continuation
      do { try input.write(contentsOf: bytes) } catch {
        pending.removeValue(forKey: id)?.resume(throwing: error)
      }
      Task { [weak self] in
        try? await Task.sleep(for: .seconds(30))
        guard let self, self.generation == token else { return }
        self.pending.removeValue(forKey: id)?.resume(
          throwing: AgentFailure(message: "Agent 请求超时：\(method)"))
      }
    }
  }

  func stop() async {
    guard let child = process else { return }
    stopping = true
    try? input?.close()
    input = nil
    // EOF requests cancellation. Wait without blocking the UI before falling back to SIGTERM.
    for _ in 0..<100 {
      if !child.isRunning { break }
      try? await Task.sleep(for: .milliseconds(50))
    }
    if child.isRunning { child.terminate() }
    for _ in 0..<100 {
      if !child.isRunning { break }
      try? await Task.sleep(for: .milliseconds(50))
    }
    if child.isRunning { kill(child.processIdentifier, SIGKILL) }
    finishPending("Agent 连接已关闭")
    process = nil
    generation = UUID()
  }

  private func receive(_ bytes: Data, token: UUID) {
    guard generation == token else { return }
    do {
      for frame in try decoder.append(bytes) {
        if let id = frame["id"].int {
          if let continuation = pending.removeValue(forKey: id) {
            if let message = frame["error"]["message"].text {
              continuation.resume(throwing: AgentFailure(message: message))
            } else {
              continuation.resume(returning: frame["result"])
            }
          }
        } else if frame["method"].text == "run.event" {
          onEvent?(try frame["params"].decode(AgentEvent.self))
        } else if frame["method"].text == "codex.event" {
          onCodexEvent?(frame["params"])
        } else if frame["method"].text == "events.gap" {
          if frame["params"]["source"].text == "codex" { onCodexGap?() }
          else { onGap?() }
        }
      }
    } catch {
      finishPending("无法解析 Agent 响应：\(error.localizedDescription)")
      onDisconnect?("Agent 协议错误")
      process?.terminate()
    }
  }

  private func terminated(status: Int32, token: UUID) {
    guard generation == token else { return }
    process = nil
    input = nil
    let message = "Agent 已退出（\(status)）\(stderrTail.isEmpty ? "" : "\n" + stderrTail)"
    finishPending(message)
    if !stopping { onDisconnect?(message) }
  }
  private func finishPending(_ message: String) {
    let callbacks = Array(pending.values)
    pending.removeAll()
    for callback in callbacks { callback.resume(throwing: AgentFailure(message: message)) }
  }
}
