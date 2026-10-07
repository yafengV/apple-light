import Foundation

/// Bounds UI waiting even when Foundation's synchronous file open does not return.
/// Retries share an outstanding read instead of accumulating blocked I/O workers.
@MainActor final class WorkspaceLibraryReader {
  private struct Waiter {
    let continuation: CheckedContinuation<WorkspaceLibrary, Error>
    let deadline: Task<Void, Never>
  }
  private let url: URL
  private let timeout: Duration
  private let read: @Sendable (URL) throws -> WorkspaceLibrary
  private var operation: UUID?
  private var waiters: [UUID: Waiter] = [:]

  init(url: URL, timeout: Duration = .seconds(15),
    read: @escaping @Sendable (URL) throws -> WorkspaceLibrary = { try WorkspaceLibrary.load(from: $0) }) {
    self.url = url; self.timeout = timeout; self.read = read
  }

  func load() async throws -> WorkspaceLibrary {
    try Task.checkCancellation()
    let id = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
        let deadline = Task { [weak self, timeout] in
          do { try await Task.sleep(for: timeout) } catch { return }
          self?.finish(id, with: .failure(AgentFailure(message:
            "读取工作区记录超时。请检查数据目录是否可访问，然后重试；现有记录未被更改。")))
        }
        waiters[id] = Waiter(continuation: continuation, deadline: deadline)
        if operation == nil {
          let token = UUID(), url = url, read = read
          operation = token
          Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { try read(url) }
            await self?.complete(token, with: result)
          }
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.finish(id, with: .failure(CancellationError())) }
    }
  }

  private func complete(_ token: UUID, with result: Result<WorkspaceLibrary, Error>) {
    guard operation == token else { return }
    operation = nil
    // A late result has no authority to update the store after its waiter expired.
    for id in Array(waiters.keys) { finish(id, with: result) }
  }

  private func finish(_ id: UUID, with result: Result<WorkspaceLibrary, Error>) {
    guard let waiter = waiters.removeValue(forKey: id) else { return }
    waiter.deadline.cancel()
    waiter.continuation.resume(with: result)
  }
}
