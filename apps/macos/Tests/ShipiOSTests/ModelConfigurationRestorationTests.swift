import AppKit
import XCTest
@testable import ShipiOS

final class ModelConfigurationRestorationTests: XCTestCase {
  @MainActor func testInvalidModelFileStopsRestorationAndPreservesSavedHistoryUntilRetry() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var library = WorkspaceLibrary()
    library.drafts["new:none"] = "Protected draft"
    try library.save(to: root.appendingPathComponent("workspace.json"))
    let originalHistory = try Data(contentsOf: root.appendingPathComponent("workspace.json"))
    let invalid = Data("invalid model".utf8), file = root.appendingPathComponent("model.json")
    try invalid.write(to: file)
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    XCTAssertTrue(store.libraryLoaded, "Valid task history must not be reported as corrupt")
    XCTAssertNil(store.libraryReadError)
    XCTAssertFalse(store.scopeLoaded, "Do not open a workspace with unread model configuration")
    XCTAssertTrue(store.libraryRecoveryBlocksInteraction)
    XCTAssertFalse(store.restoringLibrary)
    XCTAssertFalse(store.canStartChat)
    XCTAssertEqual(try Data(contentsOf: file), invalid)
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("workspace.json")), originalHistory)
    try JSONEncoder().encode(ModelConfiguration()).write(to: file, options: .atomic)
    await store.restore()
    XCTAssertTrue(store.scopeLoaded)
    XCTAssertFalse(store.libraryRecoveryBlocksInteraction)
    XCTAssertEqual(store.draft, "Protected draft")
    await store.shutdown()
  }
  private final class BlockedRead: @unchecked Sendable {
    let started = XCTestExpectation(description: "Blocked model read started")
    private let semaphore = DispatchSemaphore(value: 0), lock = NSLock()
    private var count = 0, completed = 0
    let snapshot: ModelConfiguration
    init(_ snapshot: ModelConfiguration) { self.snapshot = snapshot }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    var completions: Int { lock.lock(); defer { lock.unlock() }; return completed }
    func release() { semaphore.signal() }
    func read(_ url: URL) throws -> ModelConfiguration? {
      lock.lock(); count += 1; let first = count == 1; lock.unlock()
      defer { lock.lock(); completed += 1; lock.unlock() }
      if first { started.fulfill(); semaphore.wait(); return snapshot }
      return try ModelConfigurationReader.readFile(url)
    }
  }

  @MainActor private func settle(_ condition: () -> Bool) async throws {
    for _ in 0..<200 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Read did not settle after fixture release")
  }

  @MainActor func testTimeoutRetrySharesIOAndLateSnapshotCannotReplaceConfigurationOrHistory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var library = WorkspaceLibrary(); library.drafts["new:none"] = "Timeout protected draft"
    try library.save(to: root.appendingPathComponent("workspace.json"))
    let history = try Data(contentsOf: root.appendingPathComponent("workspace.json"))
    var old = ModelConfiguration(); old.baseURL = "http://127.0.0.1:9999/v1"; old.model = "old"
    let file = root.appendingPathComponent("model.json")
    try JSONEncoder().encode(old).write(to: file)
    let bytes = try Data(contentsOf: file)
    let blocked = BlockedRead(old); defer { blocked.release() }
    let store = WorkspaceStore(dataRoot: root, modelConfigurationReader:
      ModelConfigurationReader(url: file, timeout: .milliseconds(80), read: blocked.read))
    let restore = Task { await store.restore() }
    await fulfillment(of: [blocked.started], timeout: 2)
    XCTAssertTrue(store.modelConfigurationLoading)
    XCTAssertFalse(store.saveLibrary())
    await restore.value
    XCTAssertTrue(store.libraryLoaded)
    XCTAssertNil(store.libraryReadError)
    XCTAssertFalse(store.scopeLoaded)
    XCTAssertFalse(store.modelConfigurationLoading)
    XCTAssertFalse(store.restoringLibrary)
    XCTAssertTrue(store.modelConfigurationReadError?.contains("超时") == true)
    XCTAssertEqual(store.restorationReadError, store.modelConfigurationReadError)
    XCTAssertTrue(store.libraryRecoveryBlocksInteraction)
    XCTAssertFalse(store.canStartChat)
    XCTAssertFalse(store.canMutateArchive)
    for command in DesktopCommand.all { XCTAssertFalse(store.commandEnabled(command.id), command.id) }
    XCTAssertFalse(store.handleWorkspaceShortcut(try XCTUnwrap(ShortcutBinding("⌘K"))))
    XCTAssertFalse(store.saveLibrary())
    XCTAssertThrowsError(try store.commitLibrary(WorkspaceLibrary()))
    let route = TaskWindowRoute(taskID: "saved", dataRoot: root)
    XCTAssertEqual(TaskWindowRestoration.resolve(route: route, dataRoot: root, loaded: true,
      restoring: false, readError: store.restorationReadError, taskExists: true, hasPresentedTask: false),
      .failed(try XCTUnwrap(store.modelConfigurationReadError)))
    XCTAssertEqual(store.detachedWorkspaceTabRestoration(nil), .failed(try XCTUnwrap(store.modelConfigurationReadError)))
    store.error = nil
    XCTAssertTrue(store.libraryRecoveryBlocksInteraction, "Dismissing a banner cannot unlock the workspace")
    await store.restore()
    XCTAssertEqual(blocked.calls, 1)
    XCTAssertEqual(try Data(contentsOf: file), bytes)
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("workspace.json")), history)
    blocked.release()
    try await settle { blocked.completions == 1 }
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertEqual(store.modelConfiguration, ModelConfiguration())
    XCTAssertFalse(store.scopeLoaded)
    var fresh = old; fresh.model = "fresh"
    try JSONEncoder().encode(fresh).write(to: file, options: .atomic)
    await store.restore()
    XCTAssertEqual(blocked.calls, 2)
    XCTAssertEqual(store.modelConfiguration, fresh)
    XCTAssertNil(store.modelConfigurationReadError)
    XCTAssertNil(store.error)
    XCTAssertFalse(store.libraryRecoveryBlocksInteraction)
    XCTAssertTrue(store.scopeLoaded)
    XCTAssertEqual(store.draft, "Timeout protected draft")
    await store.shutdown()
  }

  @MainActor func testCancelledModelRestoreDoesNotPublishLateResultAndCanRetryFreshFile() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try WorkspaceLibrary().save(to: root.appendingPathComponent("workspace.json"))
    var old = ModelConfiguration(); old.model = "cancelled snapshot"
    let blocked = BlockedRead(old); defer { blocked.release() }
    let file = root.appendingPathComponent("model.json")
    let store = WorkspaceStore(dataRoot: root,
      modelConfigurationReader: ModelConfigurationReader(url: file, read: blocked.read))
    let restore = Task { await store.restore() }
    await fulfillment(of: [blocked.started], timeout: 2)
    restore.cancel(); await restore.value
    XCTAssertFalse(store.modelConfigurationLoading)
    XCTAssertFalse(store.restoringLibrary)
    XCTAssertFalse(store.scopeLoaded)
    XCTAssertTrue(store.libraryRecoveryBlocksInteraction)
    blocked.release(); try await settle { blocked.completions == 1 }
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertEqual(store.modelConfiguration, ModelConfiguration())
    XCTAssertFalse(store.scopeLoaded)
    await store.restore()
    XCTAssertTrue(store.scopeLoaded)
    XCTAssertNil(store.modelConfigurationReadError)
    await store.shutdown()
  }

  @MainActor func testExplicitSaveSupersedesPendingReadWithoutWaitingForItsIO() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let blocked = BlockedRead(ModelConfiguration()); defer { blocked.release() }
    let file = root.appendingPathComponent("model.json")
    let store = WorkspaceStore(dataRoot: root,
      modelConfigurationReader: ModelConfigurationReader(url: file, read: blocked.read))
    let load = Task { await store.loadModelConfiguration() }
    await fulfillment(of: [blocked.started], timeout: 2)
    var invalid = ModelConfiguration(); invalid.baseURL = "invalid"
    XCTAssertThrowsError(try store.saveModelConfiguration(invalid))
    XCTAssertTrue(store.modelConfigurationLoading)
    var saved = ModelConfiguration(); saved.baseURL = "http://127.0.0.1:9999/v1"; saved.model = "explicit save"
    try store.saveModelConfiguration(saved)
    let succeeded = await load.value
    XCTAssertTrue(succeeded)
    XCTAssertFalse(store.modelConfigurationLoading)
    XCTAssertNil(store.modelConfigurationReadError)
    XCTAssertEqual(store.modelConfiguration, saved)
    blocked.release(); try await settle { blocked.completions == 1 }
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertEqual(store.modelConfiguration, saved)
    XCTAssertEqual(try ModelConfigurationReader.readFile(file), saved)
    let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
    XCTAssertEqual(permissions?.intValue, 0o600)
  }

  @MainActor func testReadStartedAfterExplicitSaveCannotReuseSupersededSnapshot() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var old = ModelConfiguration(); old.model = "superseded snapshot"
    let blocked = BlockedRead(old); defer { blocked.release() }
    let file = root.appendingPathComponent("model.json")
    let store = WorkspaceStore(dataRoot: root,
      modelConfigurationReader: ModelConfigurationReader(url: file, read: blocked.read))
    let first = Task { await store.loadModelConfiguration() }
    await fulfillment(of: [blocked.started], timeout: 2)
    var fresh = ModelConfiguration(); fresh.baseURL = "http://127.0.0.1:9999/v1"; fresh.model = "saved model"
    try store.saveModelConfiguration(fresh)
    let firstResult = await first.value
    XCTAssertTrue(firstResult)
    let next = Task { await store.loadModelConfiguration() }
    try await settle { store.modelConfigurationLoading }
    XCTAssertEqual(blocked.calls, 1, "Saving must not add another blocked I/O worker")
    blocked.release()
    let nextResult = await next.value
    XCTAssertTrue(nextResult)
    XCTAssertEqual(blocked.calls, 2, "Re-read the saved file once the superseded I/O finishes")
    XCTAssertEqual(store.modelConfiguration, fresh, "A new waiter must never receive the pre-save snapshot")
    XCTAssertEqual(try ModelConfigurationReader.readFile(file), fresh)
    XCTAssertNil(store.modelConfigurationReadError)
  }

  @MainActor func testShutdownReleasesPendingModelReadAndDoesNotApplySnapshot() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var library = WorkspaceLibrary(); library.drafts["new:none"] = "Shutdown protected draft"
    let historyURL = root.appendingPathComponent("workspace.json")
    try library.save(to: historyURL)
    let originalHistory = try Data(contentsOf: historyURL)
    var old = ModelConfiguration(); old.model = "late shutdown"
    let blocked = BlockedRead(old); defer { blocked.release() }
    let store = WorkspaceStore(dataRoot: root, modelConfigurationReader:
      ModelConfigurationReader(url: root.appendingPathComponent("model.json"), read: blocked.read))
    let restore = Task { await store.restore() }
    await fulfillment(of: [blocked.started], timeout: 2)
    await store.shutdown()
    await restore.value
    XCTAssertFalse(store.modelConfigurationLoading)
    XCTAssertFalse(store.restoringLibrary)
    XCTAssertFalse(store.scopeLoaded)
    XCTAssertEqual(store.modelConfiguration, ModelConfiguration())
    XCTAssertNil(store.modelConfigurationReadError)
    XCTAssertTrue(store.modelConfigurationRecoveryPending)
    XCTAssertEqual(try Data(contentsOf: historyURL), originalHistory)
    blocked.release(); try await settle { blocked.completions == 1 }
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertEqual(store.modelConfiguration, ModelConfiguration())
    await store.restore()
    XCTAssertEqual(blocked.calls, 1, "Shutdown must not start another read")
  }

  @MainActor func testReaderOnlyTreatsMissingFileAsEmptyAndKeepsOtherWaiterWhenOneCancels() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    XCTAssertNil(try ModelConfigurationReader.readFile(root.appendingPathComponent("model.json")))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    XCTAssertThrowsError(try ModelConfigurationReader.readFile(root))
    var saved = ModelConfiguration(); saved.model = "shared"
    let blocked = BlockedRead(saved); defer { blocked.release() }
    let reader = ModelConfigurationReader(url: root, read: blocked.read)
    let cancelled = Task { try await reader.load() }
    await fulfillment(of: [blocked.started], timeout: 2)
    let retained = Task { try await reader.load() }
    cancelled.cancel()
    do { _ = try await cancelled.value; XCTFail("Cancelled waiter returned data") }
    catch { XCTAssertTrue(error is CancellationError) }
    blocked.release()
    let result = try await retained.value
    XCTAssertEqual(result, saved)
    XCTAssertEqual(blocked.calls, 1)
  }

}
