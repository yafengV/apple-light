import XCTest

@testable import ShipiOS

@MainActor private final class FakeNotificationDelivery: NotificationDelivery {
  var status = NotificationPermission.authorized
  var requests = 0
  var notices: [CompletionNotice] = []
  var afterPermissionRead: (() -> Void)?
  var onPost: (() -> Void)?
  var grant = true
  var fail = false
  func permission() async -> NotificationPermission { afterPermissionRead?(); return status }
  func requestPermission() async throws { requests += 1; if grant { status = .authorized } }
  func post(_ notice: CompletionNotice) async throws {
    if fail { throw AgentFailure(message: "delivery failed") }
    notices.append(notice)
    onPost?()
  }
}

final class NotificationTests: XCTestCase {
  private func sampleRun(_ id: String = "run", kind: String = "chat", status: String = "succeeded") -> AgentRun {
    AgentRun(id: id, kind: kind, project: "/fixture", status: status,
      createdAt: 0, updatedAt: 1, request: .null, result: nil)
  }
  private var notice: CompletionNotice {
    CompletionNotice(id: "fixture", title: "Complete", body: "Task", destination: nil)
  }

  func testTrackerIgnoresHistoryReplayForksAndCancellation() {
    var tracker = CompletionTracker()
    tracker.seed([sampleRun("old"), sampleRun("fork"), sampleRun("active", status: "running")])
    XCTAssertFalse(tracker.completed(sampleRun("old")))
    XCTAssertFalse(tracker.completed(sampleRun("fork")))
    XCTAssertTrue(tracker.completed(sampleRun("active")))
    XCTAssertFalse(tracker.completed(sampleRun("active")))
    tracker.begin("stopped")
    XCTAssertFalse(tracker.completed(sampleRun("stopped", status: "cancelled")))
    XCTAssertFalse(tracker.completed(sampleRun("stopped")))
    XCTAssertFalse(tracker.completed(sampleRun("early")))
    tracker.begin("early")
    XCTAssertTrue(tracker.completed(sampleRun("early", status: "failed")))
  }

  @MainActor func testTimingAndDefaultPermissionPolicy() async {
    let delivery = FakeNotificationDelivery()
    let center = CompletionNotificationCenter(delivery: delivery)
    await center.deliver(notice) { (CompletionNotificationPreferences(), true) }
    XCTAssertTrue(delivery.notices.isEmpty)
    await center.deliver(notice) { (CompletionNotificationPreferences(), false) }
    XCTAssertEqual(delivery.notices.count, 1)
    await center.deliver(notice) { (.init(timing: .always), true) }
    XCTAssertEqual(delivery.notices.count, 2)
    await center.deliver(notice) { (.init(timing: .never), false) }
    XCTAssertEqual(delivery.notices.count, 2)
    delivery.status = .notDetermined
    await center.deliver(notice) { (.init(timing: .always), false) }
    XCTAssertEqual(delivery.requests, 0)
    XCTAssertEqual(delivery.notices.count, 2)
  }

  @MainActor func testAutomaticPermissionPromptIsOptInAndOnlyOncePerSession() async {
    let delivery = FakeNotificationDelivery()
    delivery.status = .notDetermined
    delivery.grant = false
    let center = CompletionNotificationCenter(delivery: delivery)
    for _ in 0..<2 {
      await center.deliver(notice) { (.init(timing: .always, promptForPermission: true), false) }
    }
    XCTAssertEqual(delivery.requests, 1)
    XCTAssertTrue(delivery.notices.isEmpty)
    delivery.grant = true
    await center.requestPermission()
    XCTAssertEqual(center.permission, .authorized)
    await center.deliver(notice) { (.init(timing: .always), false) }
    XCTAssertEqual(delivery.notices.count, 1)
  }

  @MainActor func testPolicyIsRecheckedAfterAwaitingPermission() async {
    let delivery = FakeNotificationDelivery()
    let center = CompletionNotificationCenter(delivery: delivery)
    var preferences = CompletionNotificationPreferences(timing: .always)
    delivery.afterPermissionRead = { preferences.timing = .never }
    await center.deliver(notice) { (preferences, false) }
    XCTAssertTrue(delivery.notices.isEmpty)
    XCTAssertEqual(delivery.requests, 0)
  }

  @MainActor func testDeliveryFailureAndManualTestState() async {
    let delivery = FakeNotificationDelivery()
    let center = CompletionNotificationCenter(delivery: delivery)
    delivery.fail = true
    await center.sendTest()
    XCTAssertEqual(center.error, "delivery failed")
    delivery.fail = false
    await center.sendTest()
    XCTAssertNil(center.error)
    XCTAssertEqual(delivery.notices.count, 1)
    XCTAssertNil(delivery.notices[0].destination)
    delivery.status = .denied
    await center.sendTest()
    XCTAssertEqual(delivery.notices.count, 1)
  }

  func testNoticeIdentityAndDestinationAreScopedToDataRoot() {
    let run = sampleRun()
    let task = WorkspaceTask(id: "task", project: run.project, title: "My task", runIDs: [run.id])
    let first = CompletionNotice.turn(run, task: task, root: URL(fileURLWithPath: "/first"))
    let second = CompletionNotice.turn(run, task: task, root: URL(fileURLWithPath: "/second"))
    XCTAssertNotEqual(first.id, second.id)
    XCTAssertEqual(first.body, "My task")
    XCTAssertEqual(NotificationDestination(userInfo: first.destination!.userInfo), first.destination)
    XCTAssertNil(NotificationDestination(userInfo: ["dataRoot": "/first"]))
  }

  @MainActor func testPreferencesPersistWithoutChangingOtherDataRoots() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.notificationPreferences = .init(timing: .never, promptForPermission: true)
    let restored = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    XCTAssertEqual(restored.notifications, store.notificationPreferences)
    let legacy = try JSONDecoder().decode(WorkspaceLibrary.self, from: Data("{}".utf8))
    XCTAssertNil(legacy.notifications)
    let other = WorkspaceStore(dataRoot: root.appendingPathComponent("other"))
    XCTAssertEqual(other.notificationPreferences, CompletionNotificationPreferences())
  }

  @MainActor func testPreferenceWritesCannotReplaceUnloadedOrUnsavableLibrary() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("workspace.json")
    let existing = Data(#"{"drafts":{"new:none":"keep"}}"#.utf8)
    try existing.write(to: url)
    let store = WorkspaceStore(dataRoot: root)
    store.notificationPreferences = .init(timing: .never)
    XCTAssertEqual(try Data(contentsOf: url), existing)
    XCTAssertEqual(store.notificationPreferences.timing, .background)
    store.libraryLoaded = true
    try FileManager.default.removeItem(at: url)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    store.notificationPreferences = .init(timing: .never)
    XCTAssertEqual(store.notificationPreferences.timing, .background)
    XCTAssertNotNil(store.notifications.error)
  }

  @MainActor func testCrossProjectNotificationDoesNotInterruptActiveLocalExecution() async {
    let store = WorkspaceStore()
    store.libraryLoaded = true
    store.connected = true
    store.project = URL(fileURLWithPath: "/fixture")
    store.runs = [sampleRun("active", kind: "build", status: "running")]
    store.library.tasks = [WorkspaceTask(id: "other", project: "/other", title: "Other", runIDs: ["done"])]
    let target = NotificationDestination(dataRoot: store.dataRoot.path, project: "/other", taskID: "other", runID: "done")
    let opened = await store.openNotification(target)
    XCTAssertFalse(opened)
    XCTAssertEqual(store.project?.path, "/fixture")
    XCTAssertEqual(store.activeRun?.id, "active")
    XCTAssertTrue(store.navigationBack.isEmpty)
    XCTAssertNotNil(store.error)
  }

  @MainActor func testCrossScopeNotificationCanOpenAlongsideIndependentModelSession() async {
    let store = WorkspaceStore()
    store.libraryLoaded = true
    store.connected = true
    store.project = URL(fileURLWithPath: "/fixture")
    let active = sampleRun("active", status: "running")
    store.runs = [active]
    store.library.chatRuns = [active]
    store.library.attach(active, to: nil, note: "active")
    let finished = AgentRun(id: "done", kind: "chat", project: "", status: "succeeded",
      createdAt: 0, updatedAt: 1, request: .null, result: nil)
    store.library.chatRuns.append(finished)
    store.library.attach(finished, to: nil, note: "other")
    let other = try! XCTUnwrap(store.library.task(containing: finished.id))
    let target = NotificationDestination(dataRoot: store.dataRoot.path, project: "", taskID: other.id, runID: finished.id)
    let opened = await store.openNotification(target)
    XCTAssertTrue(opened)
    XCTAssertNil(store.project)
    XCTAssertEqual(store.selection, "done")
    XCTAssertEqual(store.library.chatRuns.first(where: { $0.id == "active" })?.status, "running")
    XCTAssertEqual(store.conversationReveal?.runID, "done")
  }

  @MainActor func testNotificationNavigationChecksOwnershipAndRevealsExactTurn() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.project = URL(fileURLWithPath: "/fixture")
    store.connected = true
    store.runs = [sampleRun("one"), sampleRun("two")]
    store.library.attach(store.runs[0], to: nil, note: "first")
    store.library.attach(store.runs[1], to: "one", note: "second")
    let target = NotificationDestination(dataRoot: root.path, project: "/fixture", taskID: "one", runID: "one")
    let opened = await store.openNotification(target)
    XCTAssertTrue(opened)
    XCTAssertEqual(store.selection, "one")
    XCTAssertEqual(store.conversationReveal?.runID, "one")
    let previous = store.conversationReveal?.id
    _ = await store.openNotification(target)
    XCTAssertNotEqual(store.conversationReveal?.id, previous)
    for invalid in [
      NotificationDestination(dataRoot: "/other", project: "/fixture", taskID: "one", runID: "two"),
      NotificationDestination(dataRoot: root.path, project: "/foreign", taskID: "one", runID: "two"),
      NotificationDestination(dataRoot: root.path, project: "/fixture", taskID: "one", runID: "missing"),
    ] {
      let result = await store.openNotification(invalid)
      XCTAssertFalse(result)
      XCTAssertEqual(store.selection, "one")
    }
  }

  @MainActor func testStoreCompletionIsDeliveredOnceThroughInjectedService() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    let delivery = FakeNotificationDelivery()
    let delivered = expectation(description: "notification delivered")
    delivery.onPost = { delivered.fulfill() }
    store.notifications = CompletionNotificationCenter(delivery: delivery)
    store.library.notifications = .init(timing: .always)
    store.library.attach(sampleRun(), to: nil, note: "Notify this task")
    store.completionTracker.begin("run")
    store.observeCompletions([sampleRun(), sampleRun()])
    await fulfillment(of: [delivered], timeout: 2)
    XCTAssertEqual(delivery.notices.count, 1)
    XCTAssertEqual(delivery.notices.first?.destination?.taskID, "run")
  }
}
