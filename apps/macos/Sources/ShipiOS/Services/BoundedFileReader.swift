import Foundation

/// Bounds UI waiting even when Foundation's synchronous file open does not return.
/// Retries share an outstanding read instead of accumulating blocked I/O workers.
@MainActor final class BoundedFileReader<Value> {
  private struct Waiter {
    let continuation: CheckedContinuation<Value, Error>
    let deadline: Task<Void, Never>
  }
  private let url: URL
  private let timeout: Duration
  private let timeoutMessage: String
  private let read: @Sendable (URL) throws -> Value
  private var operation: UUID?
  private var invalidatedOperation: UUID?
  private var waiters: [UUID: Waiter] = [:]

  init(url: URL, timeout: Duration, timeoutMessage: String,
    read: @escaping @Sendable (URL) throws -> Value) {
    self.url = url; self.timeout = timeout; self.timeoutMessage = timeoutMessage; self.read = read
  }

  func cancelPending() {
    // Explicit saves invalidate the operation too, not just its current waiters.
    // A later load may wait for that I/O to finish, but must read the new file.
    invalidatedOperation = operation
    for id in Array(waiters.keys) { finish(id, with: .failure(CancellationError())) }
  }

  func load() async throws -> Value {
    try Task.checkCancellation()
    let id = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
        let deadline = Task { [weak self, timeout, timeoutMessage] in
          do { try await Task.sleep(for: timeout) } catch { return }
          self?.finish(id, with: .failure(AgentFailure(message:
            timeoutMessage)))
        }
        waiters[id] = Waiter(continuation: continuation, deadline: deadline)
        if operation == nil { startRead() }
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.finish(id, with: .failure(CancellationError())) }
    }
  }

  private func startRead() {
    let token = UUID(), url = url, read = read
    operation = token
    Task.detached(priority: .userInitiated) { [weak self] in
      let result = Result { try read(url) }
      await self?.complete(token, with: result)
    }
  }

  private func complete(_ token: UUID, with result: Result<Value, Error>) {
    guard operation == token else { return }
    operation = nil
    if invalidatedOperation == token {
      invalidatedOperation = nil
      if !waiters.isEmpty { startRead() }
      return
    }
    // A late result has no authority to update the store after its waiter expired.
    for id in Array(waiters.keys) { finish(id, with: result) }
  }

  private func finish(_ id: UUID, with result: Result<Value, Error>) {
    guard let waiter = waiters.removeValue(forKey: id) else { return }
    waiter.deadline.cancel()
    waiter.continuation.resume(with: result)
  }
}
