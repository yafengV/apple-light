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
  private let inbox = WorkspaceFileSearchInbox()
  private var buffer = Data()
  private var currentID = 0
  private var continuation: AsyncThrowingStream<WorkspaceFileSearchUpdate, Error>.Continuation?
  private var deadline: Task<Void, Never>?
  private var deadlineRevision = UUID()
  private var closed = false
  private let timeout: Duration
  private let timeoutSleep: @Sendable (Duration) async throws -> Void
  var processIdentifier: Int32 { process.processIdentifier }

  init(root: URL, executable: URL, timeout: Duration = .seconds(20), additionalRoots: [URL] = [],
    timeoutSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    beforeResponseDelivery: (@Sendable () async -> Void)? = nil) throws {
    self.timeout = timeout
    self.timeoutSleep = timeoutSleep
    let child = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    process = child; input = stdin.fileHandleForWriting
    child.executableURL = executable
    child.arguments = ["--project", root.path, "search-files-session"]
      + Array(WorkspaceFileScope.roots(primary: root, additional: additionalRoots).dropFirst())
        .flatMap { ["--additional-root", $0.path] }
    child.currentDirectoryURL = root
    child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8"]
    child.standardInput = stdin; child.standardOutput = stdout; child.standardError = stderr
    try child.run()
    let inbox = self.inbox
    // Events may coalesce: the inbox retains every byte until actor delivery.
    let (stream, emitter) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    DispatchQueue.global(qos: .userInitiated).async {
      while true {
        let data = stdout.fileHandleForReading.availableData
        if data.isEmpty { break }
        guard inbox.append(data) else { break }
        emitter.yield(())
      }
      inbox.finish()
      emitter.finish()
    }
    // Drain diagnostics without exposing file paths or environment variables in logs.
    DispatchQueue.global(qos: .utility).async {
      while !stderr.fileHandleForReading.availableData.isEmpty {}
    }
    Task { [weak self] in
      for await _ in stream {
        if let beforeResponseDelivery { await beforeResponseDelivery() }
        self?.drainReceivedData()
      }
      self?.drainReceivedData()
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
    inbox.stop()
    cancelCurrent()
    try? input.close()
    // Terminate promptly as well, including when a filesystem walker is stalled.
    if process.isRunning { process.terminate() }
  }

  deinit {
    inbox.stop()
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

  private func drainReceivedData() {
    guard !closed else { return }
    let batch = inbox.take()
    for data in batch.chunks {
      receive(data)
      if closed { return }
    }
    if batch.ended { fail(AgentFailure(message: "文件搜索进程已退出，请重试。")) }
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
    let revision = UUID(); deadlineRevision = revision
    deadline = Task { [weak self, timeout, timeoutSleep] in
      do { try await timeoutSleep(timeout) } catch { return }
      guard !Task.isCancelled, let self, self.deadlineRevision == revision,
        self.currentID == id, self.continuation != nil else { return }
      // A ready timeout may run before the ordinary response-delivery task.
      // Decode already-read frames first; only valid current-query progress
      // renews the deadline, and completion cancels it altogether.
      self.drainReceivedData()
      guard !Task.isCancelled, !self.closed, self.deadlineRevision == revision,
        self.currentID == id, self.continuation != nil else { return }
      self.fail(AgentFailure(message: "文件搜索超时，请重试。"))
    }
  }
  private func fail(_ error: Error) {
    guard !closed else { return }
    continuation?.finish(throwing: error); continuation = nil
    close()
  }
}
