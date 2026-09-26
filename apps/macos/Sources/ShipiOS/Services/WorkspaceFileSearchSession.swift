import Foundation

struct WorkspaceFileSearchUpdate: Decodable, Sendable {
  let id: Int
  let files: [WorkspaceFileSearchResult]
  let complete: Bool
}

@MainActor protocol FileSearchSession: AnyObject {
  func query(_ text: String) throws -> AsyncThrowingStream<WorkspaceFileSearchUpdate, Error>
  func cancelQuery()
  func close()
}

/// Private read-only helper protocol. Each search dialog owns its process and index.
@MainActor final class WorkspaceFileSearchSession: FileSearchSession {
  private let process: Process
  private let input: FileHandle
  private var buffer = Data()
  private var currentID = 0
  private var continuation: AsyncThrowingStream<WorkspaceFileSearchUpdate, Error>.Continuation?
  private var deadline: Task<Void, Never>?
  private var closed = false
  private let timeout: Duration
  var processIdentifier: Int32 { process.processIdentifier }

  init(root: URL, executable: URL, timeout: Duration = .seconds(20)) throws {
    self.timeout = timeout
    let child = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    process = child; input = stdin.fileHandleForWriting
    child.executableURL = executable
    child.arguments = ["--project", root.path, "search-files-session"]
    child.currentDirectoryURL = root
    child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8"]
    child.standardInput = stdin; child.standardOutput = stdout; child.standardError = stderr
    try child.run()
    let (stream, emitter) = AsyncStream<Data>.makeStream()
    DispatchQueue.global(qos: .userInitiated).async {
      while true {
        let data = stdout.fileHandleForReading.availableData
        if data.isEmpty { break }
        emitter.yield(data)
      }
      emitter.finish()
    }
    // Drain diagnostics without exposing file paths or environment variables in logs.
    DispatchQueue.global(qos: .utility).async {
      while !stderr.fileHandleForReading.availableData.isEmpty {}
    }
    Task { [weak self] in
      for await data in stream { self?.receive(data) }
      self?.fail(AgentFailure(message: "文件搜索进程已退出，请重试。"))
    }
  }

  func query(_ text: String) throws -> AsyncThrowingStream<WorkspaceFileSearchUpdate, Error> {
    guard !closed, process.isRunning else { throw AgentFailure(message: "文件搜索进程不可用，请重试。") }
    cancelCurrent()
    currentID += 1
    let id = currentID
    let (stream, emitter) = AsyncThrowingStream<WorkspaceFileSearchUpdate, Error>.makeStream()
    continuation = emitter
    emitter.onTermination = { [weak self] _ in
      Task { @MainActor in
        guard let self, self.currentID == id else { return }
        self.deadline?.cancel(); self.deadline = nil
        self.continuation = nil
      }
    }
    do { try write(id: id, query: text) }
    catch { fail(error); throw error }
    armDeadline(for: id)
    return stream
  }

  func cancelQuery() {
    cancelCurrent(); currentID += 1
    if !closed { try? write(id: currentID, query: "") }
  }

  func close() {
    guard !closed else { return }
    closed = true; currentID += 1
    cancelCurrent()
    try? input.close()
    // Terminate promptly as well, including when a filesystem walker is stalled.
    if process.isRunning { process.terminate() }
  }

  deinit {
    deadline?.cancel()
    try? input.close()
    if process.isRunning { process.terminate() }
  }

  private func write(id: Int, query: String) throws {
    struct Query: Encodable { let id: Int; let query: String }
    var data = try JSONEncoder().encode(Query(id: id, query: query)); data.append(10)
    guard data.count <= 65_536 else { throw AgentFailure(message: "搜索内容过长。") }
    try input.write(contentsOf: data)
  }

  private func receive(_ data: Data) {
    guard !closed else { return }
    buffer.append(data)
    while let end = buffer.firstIndex(of: 10) {
      guard buffer.distance(from: buffer.startIndex, to: end) < 1_048_576 else { fail(AgentFailure(message: "文件搜索响应过大。")); return }
      let line = Data(buffer.prefix(upTo: end)); buffer.removeSubrange(...end)
      do {
        let update = try JSONDecoder().decode(WorkspaceFileSearchUpdate.self, from: line)
        guard update.id == currentID else { continue }
        guard let emitter = continuation else { continue }
        emitter.yield(update)
        if update.complete { continuation?.finish(); continuation = nil; deadline?.cancel(); deadline = nil }
        else { armDeadline(for: update.id) }
      } catch { fail(AgentFailure(message: "文件搜索响应无效，请重试。")); return }
    }
    if buffer.count > 1_048_576 { fail(AgentFailure(message: "文件搜索响应过大。")) }
  }

  private func cancelCurrent() {
    deadline?.cancel(); deadline = nil
    continuation?.finish(throwing: CancellationError()); continuation = nil
  }
  private func armDeadline(for id: Int) {
    deadline?.cancel()
    deadline = Task { [weak self, timeout] in
      do { try await Task.sleep(for: timeout) } catch { return }
      guard let self, self.currentID == id, self.continuation != nil else { return }
      self.fail(AgentFailure(message: "文件搜索超时，请重试。"))
    }
  }
  private func fail(_ error: Error) {
    guard !closed else { return }
    continuation?.finish(throwing: error); continuation = nil
    close()
  }
}
