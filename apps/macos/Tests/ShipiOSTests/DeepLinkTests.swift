import XCTest

@testable import ShipiOS

final class DeepLinkTests: XCTestCase {
  func testSupportedDeepLinksParseAndRoundTrip() throws {
    let links: [ShipiOSDeepLink] = [
      .workspace, .projects, .plugins, .automations, .automationsList,
      .newTask(prompt: "检查中文与 Markdown\n- item", path: "/tmp/My Project", originURL: nil),
      .newTask(prompt: nil, path: nil, originURL: "git@example.com:team/repo.git"),
      .newTask(prompt: nil, path: nil, originURL: nil), .settings(nil),
      .settings(.appearance), .settings(.connections), .task("task-123"),
    ]
    for link in links {
      let url = try XCTUnwrap(link.url)
      XCTAssertEqual(ShipiOSDeepLink(url: url), link, url.absoluteString)
    }
    XCTAssertEqual(
      ShipiOSDeepLink(url: try XCTUnwrap(URL(string: "shipios://task/run%2D123"))),
      .task("run-123"))
    XCTAssertEqual(ShipiOSDeepLink.automations.url?.absoluteString, "shipios://automations")
    XCTAssertEqual(ShipiOSDeepLink.automationsList.url?.absoluteString,
      "shipios://automations/list")
    XCTAssertEqual(ShipiOSDeepLink(url: try XCTUnwrap(URL(string:
      "shipios://new?prompt=Review%20this"))),
      .newTask(prompt: "Review this", path: nil, originURL: nil))
  }

  func testMalformedOrForeignDeepLinksAreRejected() throws {
    for value in [
      "https://settings/appearance", "shipios://unknown", "shipios://settings/missing",
      "shipios://settings/appearance/extra", "shipios://task", "shipios://user:pass@plugins",
      "shipios://task/id%20with%20spaces", "shipios://automations/unknown",
      "shipios://new", "shipios://threads/old", "shipios://threads/new?prompt=a&prompt=b",
      "shipios://threads/new?unknown=value",
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

    await store.openDeepLink(.automations)
    XCTAssertEqual(store.destination, .automations)
    XCTAssertNotNil(store.automationCreateRequest)
    store.automationCreateRequest = nil
    await store.openDeepLink(.automationsList)
    XCTAssertEqual(store.destination, .automations)
    XCTAssertNil(store.automationCreateRequest)
    XCTAssertNotNil(store.automationListRequest)

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

  @MainActor func testNewTaskLinksPrefillIndependentDraftAndResolveProject() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let binary = repository.appendingPathComponent("target/debug/shipios-agent")
    XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary.path))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shipios-link-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let first = root.appendingPathComponent("First")
    let second = root.appendingPathComponent("Second")
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    _ = try await GitReviewService.checked(["init", "-q"], at: second)
    _ = try await GitReviewService.checked(
      ["remote", "add", "origin", "git@example.com:team/second.git"], at: second)
    var store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"), agentExecutable: binary)
    await store.restore()
    store.draft = "保留无项目草稿"
    await store.openDeepLink(.newTask(prompt: "standalone link", path: nil, originURL: nil))
    XCTAssertNil(store.project)
    XCTAssertEqual(store.draft, "standalone link")
    store.newTask()
    XCTAssertEqual(store.draft, "保留无项目草稿")
    await store.open(first)
    XCTAssertTrue(store.connected, store.error ?? "")
    store.draft = "保留原有项目草稿"
    await store.open(second)
    XCTAssertTrue(store.connected, store.error ?? "")
    store.draft = "保留第二项目草稿"

    await store.openDeepLink(.newTask(prompt: "检查第一项目", path: first.path,
      originURL: "git@example.com:team/second.git"))
    XCTAssertEqual(store.project?.path, first.path, "Explicit path takes precedence over originUrl")
    XCTAssertNil(store.selectedTask)
    XCTAssertEqual(store.draft, "检查第一项目")
    XCTAssertEqual(store.library.drafts["new:\(first.path)"], "保留原有项目草稿")
    XCTAssertTrue(store.library.chatRuns.isEmpty, "A deep link only pre-fills; it never sends")

    await store.openDeepLink(.newTask(prompt: "Review remote", path: nil,
      originURL: "git@example.com:team/second.git"))
    XCTAssertEqual(store.project?.path, second.path)
    XCTAssertEqual(store.draft, "Review remote")
    XCTAssertEqual(store.library.drafts["new:\(second.path)"], "保留第二项目草稿")
    let preservedDraft = store.draft
    await store.openDeepLink(.newTask(prompt: "unknown", path: nil,
      originURL: "git@example.com:team/missing.git"))
    XCTAssertEqual(store.draft, preservedDraft)
    XCTAssertTrue(store.error?.contains("找不到") == true)
    await store.shutdown()
    store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"), agentExecutable: binary)
    await store.restore()
    XCTAssertEqual(store.project?.path, second.path)
    XCTAssertEqual(store.draft, "Review remote", "The deep-linked draft must survive app restoration")
    store.newTask()
    XCTAssertEqual(store.draft, "保留第二项目草稿")
    await store.openDeepLink(.newTask(prompt: nil, path: nil, originURL: nil))
    XCTAssertEqual(store.project?.path, second.path)
    XCTAssertEqual(store.draft, "")
    XCTAssertTrue(store.library.chatRuns.isEmpty)
    await store.openDeepLink(.newTask(prompt: "bad path", path: "relative/folder", originURL: nil))
    XCTAssertEqual(store.draft, "")
    XCTAssertTrue(store.error?.contains("绝对路径") == true)
    await store.shutdown()
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
