import XCTest

@testable import ShipiOS

final class DeepLinkTests: XCTestCase {
  func testSupportedDeepLinksParseAndRoundTrip() throws {
    let links: [ShipiOSDeepLink] = [
      .workspace, .projects, .plugins, .automations, .settings(nil),
      .settings(.appearance), .settings(.connections), .task("task-123"),
    ]
    for link in links {
      let url = try XCTUnwrap(link.url)
      XCTAssertEqual(ShipiOSDeepLink(url: url), link, url.absoluteString)
    }
    XCTAssertEqual(
      ShipiOSDeepLink(url: try XCTUnwrap(URL(string: "shipios://task/run%2D123"))),
      .task("run-123"))
  }

  func testMalformedOrForeignDeepLinksAreRejected() throws {
    for value in [
      "https://settings/appearance", "shipios://unknown", "shipios://settings/missing",
      "shipios://settings/appearance/extra", "shipios://task", "shipios://user:pass@plugins",
      "shipios://task/id%20with%20spaces",
    ] {
      XCTAssertNil(ShipiOSDeepLink(url: try XCTUnwrap(URL(string: value))), value)
    }
  }

  @MainActor func testPageAndTaskLinksUseExistingMainWindowNavigation() async {
    let store = WorkspaceStore()
    store.showPlugins()
    await store.openDeepLink(.settings(.connections))
    XCTAssertEqual(store.destination, .settings)
    XCTAssertEqual(store.settingsPage, .connections)
    store.closeSettings()
    XCTAssertEqual(store.destination, .plugins)

    let run = AgentRun(
      id: "run-link", kind: "chat", project: "", status: "succeeded",
      createdAt: 1, updatedAt: 1, request: .null,
      result: .object(["response": .string("linked")]))
    store.library.attach(run, to: nil, note: "Deep-linked task")
    store.library.chatRuns.append(run)
    await store.openDeepLink(.task("run-link"))
    XCTAssertEqual(store.destination, .workspace)
    XCTAssertEqual(store.selection, "run-link")
    XCTAssertEqual(store.selectedTask?.title, "Deep-linked task")

    await store.openDeepLink(.task("missing"))
    XCTAssertEqual(store.selection, "run-link")
    XCTAssertEqual(store.error, "找不到深链接指定的任务。")
  }

  @MainActor func testTaskShareTextContainsConversationAndLocalLink() throws {
    let store = WorkspaceStore()
    let first = AgentRun(
      id: "first", kind: "chat", project: "", status: "succeeded",
      createdAt: 1, updatedAt: 1, request: .null,
      result: .object(["response": .string("先检查项目。")]))
    let second = AgentRun(
      id: "second", kind: "doctor", project: "", status: "succeeded",
      createdAt: 2, updatedAt: 2, request: .null,
      result: .object(["summary": .string("环境检查完成。")]))
    let task = WorkspaceTask(
      id: "share-task", project: "", title: "共享验收", runIDs: [first.id, second.id])
    store.runs = [first, second]
    store.library.tasks = [task]
    store.library.notes[first.id] = "检查这个项目"
    store.library.notes[second.id] = "运行环境检查"

    let text = store.taskShareText(task)

    XCTAssertTrue(text.hasPrefix("# 共享验收\n"))
    XCTAssertTrue(text.contains("## 用户\n\n检查这个项目"))
    XCTAssertTrue(text.contains("## ShipiOS\n\n先检查项目。"))
    XCTAssertTrue(text.contains("环境检查完成。"))
    XCTAssertTrue(text.contains("shipios://task/share-task"))
  }

  @MainActor func testCopyTaskLinkAvailabilityAndURL() throws {
    let store = WorkspaceStore()
    let first = WorkspaceTask(id: "first-task", project: "", title: "First", runIDs: [])
    let second = WorkspaceTask(id: "second-task", project: "", title: "Second", runIDs: [])
    store.library.tasks = [first, second]
    store.selectTask(second)
    XCTAssertTrue(store.commandEnabled("copy-task-link"))
    XCTAssertEqual(store.shortcuts.binding("copy-task-link"), ShortcutBinding("⌘⌥L"))
    XCTAssertEqual(ShipiOSDeepLink.task(second.id).url?.absoluteString, "shipios://task/second-task")
    store.openSettings(.general)
    XCTAssertFalse(store.commandEnabled("copy-task-link"))
  }

  @MainActor func testCodexSessionIDUsesPersistedThreadIdentity() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    let first = WorkspaceTask(id: "first-task", project: "", title: "First", runIDs: [])
    let second = WorkspaceTask(id: "second-task", project: "", title: "Second", runIDs: [])
    store.library.tasks = [first, second]
    store.selection = first.id
    XCTAssertFalse(store.commandEnabled("copy-session-id"))
    let threadID = UUID().uuidString
    store.recordCodexThreadID(taskID: first.id, threadID: "not-a-uuid")
    XCTAssertNil(store.selectedTask?.codexThreadID)
    store.recordCodexThreadID(taskID: first.id, threadID: threadID)
    XCTAssertEqual(store.selectedTask?.copyableCodexThreadID, threadID)
    XCTAssertTrue(store.commandEnabled("copy-session-id"))
    let persisted = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    XCTAssertEqual(persisted.tasks.first?.codexThreadID, threadID)
    store.selection = second.id
    XCTAssertFalse(store.commandEnabled("copy-session-id"))
    store.selection = first.id
    store.openSettings(.general)
    XCTAssertFalse(store.commandEnabled("copy-session-id"))
    let legacy = try JSONDecoder().decode(WorkspaceTask.self, from: JSONEncoder().encode(first))
    XCTAssertNil(legacy.codexThreadID)
  }
}
