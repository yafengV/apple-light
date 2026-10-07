import Foundation

/// The reader owns arrival order; actor scheduling must not hide bytes that
/// were already read when a deadline examines the transport.
final class WorkspaceFileSearchInbox: @unchecked Sendable {
  private let lock = NSLock()
  private var chunks: [Data] = []
  private var ended = false
  private var stopped = false

  func append(_ data: Data) -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard !stopped else { return false }
    chunks.append(data)
    return true
  }

  func finish() {
    lock.lock(); defer { lock.unlock() }
    ended = true
  }

  func take() -> (chunks: [Data], ended: Bool) {
    lock.lock(); defer { lock.unlock() }
    let batch = chunks
    chunks = []
    return (batch, ended)
  }

  func stop() {
    lock.lock(); defer { lock.unlock() }
    stopped = true; chunks = []
  }
}
