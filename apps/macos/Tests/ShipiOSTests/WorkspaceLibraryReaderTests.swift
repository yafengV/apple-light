import AppKit
import XCTest
@testable import ShipiOS

final class WorkspaceLibraryReaderTests: XCTestCase {
  private final class BlockedRead: @unchecked Sendable {
    let started = XCTestExpectation(description: "Synchronous read started")
    private let releaseFirst = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var count = 0
    private var completed = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    var completions: Int { lock.lock(); defer { lock.unlock() }; return completed }
    func release() { releaseFirst.signal() }
    func read(_ url: URL) throws -> WorkspaceLibrary {
      lock.lock(); count += 1; let first = count == 1; lock.unlock()
      if first { started.fulfill(); releaseFirst.wait() }
      defer { lock.lock(); completed += 1; lock.unlock() }
      return try WorkspaceLibrary.load(from: url)
    }
  }

  @MainActor private func settle(_ condition: () -> Bool) async throws {
    for _ in 0..<200 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("The read did not complete after releasing its fixture")
  }

  @MainActor func testTimeoutReleasesRestorationWithoutRewritingAndRetrySharesBlockedRead() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("workspace.json")
    var original = WorkspaceLibrary()
    original.drafts["new:none"] = "Original protected draft"
    try original.save(to: url)
    let originalBytes = try Data(contentsOf: url)
    let blocked = BlockedRead(); defer { blocked.release() }
    let reader = WorkspaceLibraryReader(url: url, timeout: .milliseconds(80), read: blocked.read)
    let store = WorkspaceStore(dataRoot: root, libraryReader: reader)
    let first = Task { await store.restore() }
    await fulfillment(of: [blocked.started], timeout: 2)
    await first.value
    XCTAssertFalse(store.libraryLoaded)
    XCTAssertFalse(store.libraryLoading)
    XCTAssertFalse(store.restoringLibrary)
    XCTAssertFalse(store.busy)
    XCTAssertTrue(store.libraryReadError?.contains("超时") == true)
    XCTAssertTrue(store.libraryRecoveryBlocksInteraction)
    XCTAssertFalse(store.canStartChat)
    for command in DesktopCommand.all { XCTAssertFalse(store.commandEnabled(command.id), command.id) }
    XCTAssertFalse(store.handleWorkspaceShortcut(try XCTUnwrap(ShortcutBinding("⌘K"))))
    XCTAssertFalse(store.saveLibrary())
    XCTAssertEqual(try Data(contentsOf: url), originalBytes)
    await store.restore()
    XCTAssertEqual(blocked.calls, 1, "Retry must share a read that has not returned")
    XCTAssertFalse(store.libraryLoaded)
    blocked.release()
    try await settle { blocked.completions == 1 }
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertFalse(store.libraryLoaded, "A timed-out result cannot restore the store later")
    XCTAssertTrue(store.library.drafts.isEmpty)
    var repaired = original
    repaired.drafts["new:none"] = "Fresh disk draft"
    try repaired.save(to: url)
    await store.restore()
    XCTAssertEqual(blocked.calls, 2)
    XCTAssertTrue(store.libraryLoaded)
    XCTAssertNil(store.libraryReadError)
    XCTAssertFalse(store.libraryRecoveryBlocksInteraction)
    XCTAssertEqual(store.draft, "Fresh disk draft", "Retry after completion must read the current file")
  }

  @MainActor func testCancellingOneWaiterDoesNotCancelAnotherOrPublishLateData() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("workspace.json")
    var original = WorkspaceLibrary(); original.drafts["new:none"] = "Shared read"
    try original.save(to: url)
    let blocked = BlockedRead(); defer { blocked.release() }
    let reader = WorkspaceLibraryReader(url: url, timeout: .seconds(3), read: blocked.read)
    let cancelled = Task { try await reader.load() }
    await fulfillment(of: [blocked.started], timeout: 2)
    let retained = Task { try await reader.load() }
    cancelled.cancel()
    do { _ = try await cancelled.value; XCTFail("Cancelled waiter returned data") }
    catch { XCTAssertTrue(error is CancellationError) }
    blocked.release()
    let result = try await retained.value
    XCTAssertEqual(result.drafts["new:none"], "Shared read")
    XCTAssertEqual(blocked.calls, 1)
  }

  @MainActor func testCancelledRestoreClearsBusyAndIgnoresLateLibrary() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("workspace.json")
    var original = WorkspaceLibrary(); original.drafts["new:none"] = "Saved only"
    try original.save(to: url)
    let blocked = BlockedRead(); defer { blocked.release() }
    let store = WorkspaceStore(dataRoot: root,
      libraryReader: WorkspaceLibraryReader(url: url, read: blocked.read))
    let restore = Task { await store.restore() }
    await fulfillment(of: [blocked.started], timeout: 2)
    restore.cancel(); await restore.value
    XCTAssertFalse(store.busy)
    XCTAssertFalse(store.libraryLoading)
    XCTAssertFalse(store.restoringLibrary)
    XCTAssertFalse(store.libraryLoaded)
    blocked.release()
    try await settle { blocked.completions == 1 }
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertFalse(store.libraryLoaded)
    XCTAssertTrue(store.library.drafts.isEmpty)
    XCTAssertEqual(try WorkspaceLibrary.load(from: url).drafts["new:none"], "Saved only")
  }
}
