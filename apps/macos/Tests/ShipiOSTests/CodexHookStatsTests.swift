import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

final class CodexHookStatsTests: XCTestCase {
  private func hook(_ id: String, status: String = "completed", event: String = "stop", source: String = "plugin",
    order: Int = 0, started: Int = 1, completed: Int? = 2, message: String? = nil, entries: [CodexHookRun.Entry] = []) -> CodexHookRun {
    .init(hookID: id, startedAt: started, completedAt: status == "running" ? nil : completed, eventName: event, source: source, status: status, statusMessage: message, displayOrder: order, entries: entries)
  }
  private func run(_ id: String = "run", status: String = "succeeded", hooks: [CodexHookRun] = []) throws -> AgentRun {
    let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(hooks))
    return .init(id: id, kind: "chat", project: "", status: status, createdAt: 1, updatedAt: 2,
      request: .object([:]), result: .object(["response": .string("answer"), "codex_hook_runs": json,
        "codex_turn_id": .string(id + "-turn"), "codex_thread_id": .string("thread")]))
  }
  private func event(_ hook: CodexHookRun, turn: String = "run-turn", type: String = "hook_completed") throws -> JSONValue {
    .object(["type": .string(type), "turn_id": .string(turn),
      "run": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(hook))])
  }

  func testFinishedCountsSourceBucketsAndContextFilteringMatchReference() throws {
    let hooks = [hook("pending", status: "running"), hook("failed", status: "failed", order: 3),
      hook("blocked", status: "blocked", order: 1), hook("stopped", status: "stopped", order: 2),
      hook("finished", order: 0, message: "  done  ", entries: [.init(kind: "context", text: "model-only"),
        .init(kind: "warning", text: "message"), .init(kind: "feedback", text: "feedback"), .init(kind: "future", text: "unknown")])]
    let stats = try XCTUnwrap(CodexHookStats(hooks))
    XCTAssertEqual(stats.count, 4); XCTAssertEqual(stats.blockedCount, 1); XCTAssertEqual(stats.errorCount, 1)
    XCTAssertEqual(stats.runs.map(\.id), ["failed", "blocked", "stopped", "finished"])
    XCTAssertEqual(stats.runs[3].visibleEntries.map(\.text), ["message", "feedback"])
    XCTAssertEqual(stats.runs[3].visibleStatusMessage, "done"); XCTAssertNil(stats.runs[3].fallbackMessage)
    XCTAssertNil(CodexHookStats([hook("running", status: "running")]))
    XCTAssertNil(try run(status: "running", hooks: hooks).codexHookStats)
    XCTAssertEqual(try run(hooks: hooks).codexHookRuns, hooks)
    for source in ["system", "mdm", "cloud_requirements", "cloud_managed_config", "legacy_managed_config_file", "legacy_managed_config_mdm"] {
      XCTAssertEqual(hook(source, source: source).sourceLabel, "管理员")
    }
    XCTAssertEqual(hook("s", source: "session_flags").sourceLabel, "会话")
    XCTAssertEqual(hook("u", status: "future", source: "future").statusLabel, "未知")
    XCTAssertEqual(hook("u", source: "future").sourceLabel, "未知")
    XCTAssertNotNil(hook("b", status: "blocked").fallbackMessage)
    XCTAssertNotNil(hook("e", status: "failed").fallbackMessage)
    XCTAssertNotNil(hook("s", status: "stopped").fallbackMessage)
  }

  @MainActor func testLateHistoryDeduplicatesCannotCrossTaskThreadOrTurnAndRestores() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("hook-history-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    await store.openProjectless()
    let taskID = UUID().uuidString
    store.library.tasks.append(.init(id: taskID, project: "", title: "History", runIDs: []))
    let index = try XCTUnwrap(store.library.tasks.firstIndex { $0.id == taskID })
    store.library.tasks[index].codexThreadID = "thread"
    store.library.tasks[index].runIDs = ["run", "next"]
    store.library.chatRuns = [try run(), try run("next", status: "running")]
    let started = try event(hook("h", status: "running"), type: "hook_started")
    store.recordCodexHook(taskID: taskID, threadID: "thread", event: started)
    let completed = try event(hook("h", status: "failed", entries: [.init(kind: "error", text: "late failure")]))
    store.recordCodexHook(taskID: taskID, threadID: "thread", event: completed)
    store.recordCodexHook(taskID: taskID, threadID: "thread", event: completed)
    store.recordCodexHook(taskID: taskID, threadID: "thread", event: started)
    XCTAssertEqual(store.library.chatRuns[0].codexHookRuns.count, 1)
    XCTAssertEqual(store.library.chatRuns[0].codexHookStats?.errorCount, 1)
    XCTAssertTrue(store.library.chatRuns[1].codexHookRuns.isEmpty)
    for (task, thread, turn) in [("other", "thread", "run-turn"), (taskID, "other", "run-turn"), (taskID, "thread", "other-turn")] {
      store.recordCodexHook(taskID: task, threadID: thread, event: try event(hook("foreign"), turn: turn))
    }
    var session = try event(hook("session", event: "session_start"))
    if case .object(var fields) = session { fields["turn_id"] = .null; session = .object(fields) }
    store.recordCodexHook(taskID: taskID, threadID: "thread", event: session)
    XCTAssertEqual(store.library.chatRuns[0].codexHookRuns.map(\.id), ["h"])
    XCTAssertEqual(store.library.chatRuns[1].codexHookRuns.map(\.id), ["session"])
    store.recordCodexHook(taskID: taskID, threadID: "thread", event: try event(hook("h", status: "running", started: 10), type: "hook_started"))
    store.recordCodexHook(taskID: taskID, threadID: "thread", event: try event(hook("h", started: 10, completed: 11)))
    XCTAssertEqual(store.library.chatRuns[0].codexHookRuns.map(\.id), ["h", "h:1"])
    XCTAssertEqual(store.library.chatRuns[0].codexHookStats?.count, 2)
    store.saveLibrary(); await store.shutdown()
    let restored = WorkspaceStore(dataRoot: root); await restored.restore()
    let saved = try XCTUnwrap(restored.library.chatRuns.first { $0.id == "run" })
    XCTAssertEqual(saved.codexHookStats?.errorCount, 1)
    XCTAssertEqual(saved.result?["response"].text, "answer")
    await restored.shutdown()
  }

  @MainActor func testNativeDialogOwnsWindowFocusScrollAndIndependentExpanders() throws {
    _ = NSApplication.shared
    let hooks = [hook("one", entries: [.init(kind: "warning", text: String(repeating: "长输出\n", count: 80))]),
      hook("two", status: "blocked"), hook("three", status: "stopped")]
    for size in [NSSize(width: 1000, height: 760), NSSize(width: 420, height: 480)] {
      let window = NSWindow(contentRect: .init(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      let content = NSView(frame: .init(origin: .zero, size: size)), anchor = WindowDialogHost.Anchor()
      content.addSubview(anchor); window.contentView = content
      var showing = true
      let presenter = HookStatsDialogPresenter(showing: .init(get: { showing }, set: { showing = $0 }), run: try run(hooks: hooks))
      let owner = HookStatsDialogPresenter.Coordinator(presenter); anchor.host = owner.host
      owner.host.present(anchor)
      let surface = try XCTUnwrap(owner.host.surface as? HookStatsDialogPresenter.Surface)
      surface.layoutSubtreeIfNeeded()
      XCTAssertTrue(surface.window === window); XCTAssertNil(window.attachedSheet)
      XCTAssertTrue(WindowModalInteraction.blocksCommands(in: window))
      XCTAssertEqual(surface.focusTargets.first as? NSButton, surface.close)
      XCTAssertTrue(surface.expanded.isEmpty)
      XCTAssertTrue(surface.rows[0].button.accessibilityPerformPress()); surface.layoutSubtreeIfNeeded()
      XCTAssertTrue(surface.rows[1].button.accessibilityPerformPress()); surface.layoutSubtreeIfNeeded()
      XCTAssertEqual(surface.expanded, ["one", "two"])
      XCTAssertGreaterThan(surface.document.frame.height, surface.scroll.contentSize.height)
      XCTAssertLessThanOrEqual(surface.dialogFrame.maxX, surface.bounds.maxX)
      XCTAssertLessThanOrEqual(surface.dialogFrame.maxY, surface.bounds.maxY)
      XCTAssertEqual(surface.rows[2].run.statusLabel, "已停止")
      let original = surface.rows[0].button
      surface.update(stats: try XCTUnwrap(CodexHookStats(hooks + [hook("new", status: "failed")])), preferences: .init())
      XCTAssertTrue(surface.rows[0].button === original); XCTAssertEqual(surface.expanded, ["one", "two"])
      XCTAssertEqual(surface.countValues.map(\.stringValue), ["4", "1", "1"])
      func key(_ code: UInt16, characters: String = "", modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
          windowNumber: window.windowNumber, context: nil, characters: characters,
          charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
      }
      window.makeFirstResponder(surface.close)
      XCTAssertTrue(owner.host.handle(try key(48)))
      XCTAssertTrue(window.firstResponder === surface.scroll, "Unexpected focus: \(String(describing: window.firstResponder))")
      XCTAssertTrue(owner.host.handle(try key(48, modifiers: .shift)))
      XCTAssertTrue(window.firstResponder === surface.close, "Unexpected focus: \(String(describing: window.firstResponder))")
      window.makeFirstResponder(surface.rows[2].button)
      XCTAssertTrue(owner.host.handle(try key(49, characters: " ")))
      XCTAssertTrue(surface.expanded.contains("three"))
      surface.layoutSubtreeIfNeeded()
      if let directory = ProcessInfo.processInfo.environment["SHIPIOS_HOOK_STATS_RENDER_DIRECTORY"] {
        let bitmap = try XCTUnwrap(surface.bitmapImageRepForCachingDisplay(in: surface.bounds))
        surface.cacheDisplay(in: surface.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
          to: URL(fileURLWithPath: directory).appendingPathComponent("hook-stats-\(Int(size.width)).png"), options: .atomic)
      }
      let closeKey = size.width > 500 ? try key(53) : try key(13, characters: "w", modifiers: .command)
      XCTAssertTrue(owner.host.handle(closeKey)); XCTAssertFalse(showing); XCTAssertNil(owner.host.surface)
      XCTAssertFalse(WindowModalInteraction.blocksCommands(in: window))
      window.close()
    }
  }

  @MainActor func testWireCompletionAfterTerminalAndDuringAnotherTurnKeepsOriginalOwner() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("hook-wire-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("fixture-agent")
    try #"""
    #!/usr/bin/python3
    import sys, json, threading
    lock = threading.Lock()
    thread_id = "00000000-0000-4000-8000-000000000001"
    count = 0
    def send(value):
        with lock:
            print(json.dumps(value), flush=True)
    def event(task, turn, body, thread=thread_id):
        send({"jsonrpc":"2.0","method":"codex.event","params":{"taskId":task,"threadId":thread,"event":dict(body,turn_id=turn)}})
    def hook(task, turn, status, thread=thread_id):
        event(task,turn,{"type":"hook_started" if status=="running" else "hook_completed","run":{
            "id":"wire-hook","event_name":"stop","source":"plugin","status":status,
            "display_order":0,"started_at":1,"completed_at":None if status=="running" else 2,
            "status_message":None,"entries":[]}},thread)
    for line in sys.stdin:
        request = json.loads(line)
        method = request["method"]; params = request.get("params", {})
        result = {"protocolVersion":1} if method=="initialize" else {}
        if method=="codex.thread.start": result={"threadId":thread_id,"resumed":False}
        if method=="codex.turn.submit":
            count += 1; task=params["taskId"]; turn="wire-turn-"+str(count)
            send({"jsonrpc":"2.0","id":request["id"],"result":{"turnId":turn}})
            event(task,turn,{"type":"task_started"})
            if count==1:
                hook(task,turn,"running")
                event(task,turn,{"type":"task_complete","last_agent_message":"first reply"})
                threading.Timer(1,lambda task=task,turn=turn: hook(task,turn,"completed")).start()
                threading.Timer(1.1,lambda task=task,turn=turn: hook(task,turn,"completed")).start()
                threading.Timer(.8,lambda turn=turn: hook("foreign-task",turn,"failed")).start()
                threading.Timer(.9,lambda task=task,turn=turn: hook(task,"wire-turn-2","failed","foreign-thread")).start()
            else:
                threading.Timer(2,lambda task=task,turn=turn: event(task,turn,{"type":"task_complete","last_agent_message":"second reply"})).start()
            continue
        send({"jsonrpc":"2.0","id":request["id"],"result":result})
    """#.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"), agentExecutable: executable)
    await store.restore(); await store.openProjectless()
    var config = ModelConfiguration(); config.baseURL = "http://127.0.0.1:1/v1"; config.model = "gpt-5.4"; config.apiProtocol = .codexResponses
    try store.saveModelConfiguration(config); store.notificationPreferences = .init(timing: .never)
    store.draft = "First wire turn"; await store.sendDraft()
    let task = try XCTUnwrap(store.selectedTask), first = try XCTUnwrap(task.runIDs.first)
    await store.modelTask(runID: first)?.value
    XCTAssertEqual(store.library.chatRuns.first { $0.id == first }?.codexHookRuns.map(\.status), ["running"])
    let next = await store.startChat("Second wire turn", taskID: task.id)
    let second = try XCTUnwrap(next); await store.modelTask(runID: second)?.value
    let original = try XCTUnwrap(store.library.chatRuns.first { $0.id == first })
    XCTAssertEqual(original.codexHookStats?.count, 1)
    XCTAssertEqual(original.codexHookRuns.map(\.status), ["completed"])
    XCTAssertEqual(original.result?["response"].text, "first reply")
    XCTAssertTrue(store.library.chatRuns.first { $0.id == second }?.codexHookRuns.isEmpty == true)
    XCTAssertEqual(store.library.chatRuns.first { $0.id == second }?.result?["response"].text, "second reply")
    await store.shutdown()
  }

  @MainActor private func liveFixture(_ definitions: JSONValue) async throws -> (WorkspaceStore, GitGenerationFixture, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("hook-stats-live-\(UUID())")
    let source = root.appendingPathComponent("Source"), data = root.appendingPathComponent("Data")
    try FileManager.default.createDirectory(at: source.appendingPathComponent(".codex-plugin"), withIntermediateDirectories: true)
    try #"{"id":"stats-fixture","name":"Stats Fixture"}"#.write(to: source.appendingPathComponent(".codex-plugin/plugin.json"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(at: source.appendingPathComponent("hooks"), withIntermediateDirectories: true)
    try definitions.pretty.write(to: source.appendingPathComponent("hooks/hooks.json"), atomically: true, encoding: .utf8)
    _ = try PluginStorage.install(from: source, root: data)
    let server = try GitGenerationFixture(root: root)
    let store = WorkspaceStore(dataRoot: data, agentExecutable: try AgentTestExecutable.url())
    await store.restore(); await store.openProjectless(); try store.saveModelConfiguration(server.config)
    store.notificationPreferences = .init(timing: .never)
    await store.hookSettings.reload(executable: store.executable)
    let group = try XCTUnwrap(store.hookSettings.groups.first)
    store.hookSettings.open(group.id)
    await store.hookSettings.change(sourceID: group.id, expected: group.hooks, trust: true, executable: store.executable)
    XCTAssertNil(store.hookSettings.error); store.hookSettings.close()
    return (store, server, root)
  }
  private func definitions(_ handlers: [(String, String)], asynchronous: Set<String> = [], timeout: Double? = nil) -> JSONValue {
    .object(["hooks": .object(Dictionary(handlers.map { event, command in
      var fields: [String: JSONValue] = ["type": .string("command"), "command": .string(command),
        "async": .bool(asynchronous.contains(event))]
      if let timeout { fields["timeout"] = .number(timeout) }
      return (event, JSONValue.array([.object(["hooks": .array([.object(fields)])])]))
    }, uniquingKeysWith: { a, _ in a }))])
  }

  @MainActor func testRealCorePromptAndStopEventsPersistAndExcludeContextFromStats() async throws {
    let (store, server, root) = try await liveFixture(definitions([
      ("SessionStart", "printf 'SESSION-CONTEXT\\n'"), ("UserPromptSubmit", "printf 'PRIVATE-HOOK-CONTEXT\\n'"), ("Stop", "printf 'stop warning\\n' >&2; exit 1")]))
    defer { server.stop(); try? FileManager.default.removeItem(at: root) }
    store.draft = "Actual Hook stats"; await store.sendDraft()
    let task = try XCTUnwrap(store.selectedTask), id = try XCTUnwrap(task.runIDs.first)
    await store.modelTask(runID: id)?.value
    let result = try XCTUnwrap(store.library.chatRuns.first { $0.id == id })
    XCTAssertEqual(result.status, "succeeded", result.result?.pretty ?? "")
    let stats = try XCTUnwrap(result.codexHookStats, result.result?.pretty ?? "")
    XCTAssertEqual(stats.count, 3); XCTAssertEqual(stats.errorCount, 1); XCTAssertEqual(stats.blockedCount, 0)
    XCTAssertEqual(Set(stats.runs.map(\.eventName)), ["session_start", "user_prompt_submit", "stop"])
    XCTAssertTrue(stats.runs.allSatisfy { $0.source == "plugin" })
    let submit = try XCTUnwrap(stats.runs.first { $0.eventName == "user_prompt_submit" })
    XCTAssertTrue(submit.visibleEntries.isEmpty)
    XCTAssertTrue(try server.records().first?["body"].pretty.contains("PRIVATE-HOOK-CONTEXT") == true)
    XCTAssertTrue(stats.runs.first { $0.eventName == "stop" }?.visibleEntries.contains { $0.kind == "error" && $0.text.contains("code 1") } == true)
    await store.shutdown()
    let restored = WorkspaceStore(dataRoot: store.dataRoot); await restored.restore()
    XCTAssertEqual(restored.library.chatRuns.first { $0.id == id }?.codexHookStats, stats)
    await restored.shutdown()
  }

  @MainActor func testRealAsyncContextReachesNextTurnWithoutFabricatingStats() async throws {
    let (store, server, root) = try await liveFixture(definitions([
      ("UserPromptSubmit", #"sleep 2; printf 'ASYNC-HOOK-CONTEXT\n'; touch "$PLUGIN_DATA/ready""#)],
      asynchronous: ["UserPromptSubmit"]))
    defer { server.stop(); try? FileManager.default.removeItem(at: root) }
    store.draft = "First asynchronous Hook turn"; await store.sendDraft()
    let task = try XCTUnwrap(store.selectedTask), first = try XCTUnwrap(task.runIDs.first)
    await store.modelTask(runID: first)?.value
    let pending = try XCTUnwrap(store.library.chatRuns.first { $0.id == first })
    XCTAssertEqual(pending.status, "succeeded")
    XCTAssertTrue(pending.codexHookRuns.isEmpty, "Pinned Core intentionally emits UI notifications only for synchronous Hooks")
    XCTAssertNil(pending.codexHookStats)
    let directory = store.dataRoot.appendingPathComponent("Hooks/PluginData")
    var ready = false
    for _ in 0..<600 {
      ready = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?.allObjects
        .compactMap { $0 as? URL }.contains { $0.lastPathComponent == "ready" } == true
      if ready { break }; try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(ready, "The actual async shell must finish before starting the next turn")
    let next = await store.startChat("Consume asynchronous Hook results", taskID: task.id)
    let second = try XCTUnwrap(next); await store.modelTask(runID: second)?.value
    let updated = try XCTUnwrap(store.library.chatRuns.first { $0.id == first })
    XCTAssertTrue(updated.codexHookRuns.isEmpty)
    XCTAssertNil(updated.codexHookStats)
    XCTAssertTrue(store.library.chatRuns.first { $0.id == second }?.codexHookRuns.isEmpty == true)
    XCTAssertTrue(try server.records().last?["body"].pretty.contains("ASYNC-HOOK-CONTEXT") == true)
    await store.shutdown()
  }

  @MainActor func testRealToolHooksRecordBothSidesOfCommandExecution() async throws {
    let (store, server, root) = try await liveFixture(definitions([
      ("PreToolUse", "printf 'PRE-TOOL-CONTEXT\\n'"), ("PostToolUse", "printf 'POST-TOOL-CONTEXT\\n'")]))
    let model = Process(); defer { server.stop(); if model.isRunning { model.terminate(); model.waitUntilExit() }; try? FileManager.default.removeItem(at: root) }
    model.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/model_server.py")
    model.arguments = ["-u", script.path]; let output = Pipe()
    model.standardOutput = output; model.standardError = FileHandle.nullDevice; try model.run()
    let port = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    XCTAssertNotNil(Int(port)); var config = server.config; config.baseURL = "http://127.0.0.1:\(port)/v1"
    try store.saveModelConfiguration(config)
    store.draft = "codex-handoff-cwd-probe"; await store.sendDraft()
    let task = try XCTUnwrap(store.selectedTask), id = try XCTUnwrap(task.runIDs.first)
    await store.modelTask(runID: id)?.value
    let result = try XCTUnwrap(store.library.chatRuns.first { $0.id == id })
    XCTAssertEqual(result.status, "succeeded", result.result?.pretty ?? "")
    let stats = try XCTUnwrap(result.codexHookStats, result.result?.pretty ?? "")
    XCTAssertEqual(stats.count, 2); XCTAssertEqual(stats.errorCount, 0); XCTAssertEqual(stats.blockedCount, 0)
    XCTAssertEqual(stats.runs.map(\.eventName), ["pre_tool_use", "post_tool_use"])
    XCTAssertTrue(stats.runs.allSatisfy { $0.status == "completed" && $0.source == "plugin" })
    XCTAssertFalse(result.toolExecutions.isEmpty, "The actual Core must execute its shell tool")
    await store.shutdown()
  }

  @MainActor func testRealBlockedPromptCountsBlockedWithoutProviderRequest() async throws {
    let (store, server, root) = try await liveFixture(definitions([("UserPromptSubmit", "printf 'prompt denied\\n' >&2; exit 2")]))
    defer { server.stop(); try? FileManager.default.removeItem(at: root) }
    store.draft = "Blocked Hook stats"; await store.sendDraft()
    let task = try XCTUnwrap(store.selectedTask), id = try XCTUnwrap(task.runIDs.first)
    await store.modelTask(runID: id)?.value
    let result = try XCTUnwrap(store.library.chatRuns.first { $0.id == id })
    let stats = try XCTUnwrap(result.codexHookStats, result.result?.pretty ?? "")
    XCTAssertEqual(stats.count, 1); XCTAssertEqual(stats.blockedCount, 1); XCTAssertEqual(stats.errorCount, 0)
    XCTAssertEqual(stats.runs.first?.status, "blocked")
    XCTAssertTrue(stats.runs.first?.visibleEntries.contains { $0.text.contains("prompt denied") } == true)
    XCTAssertTrue(try server.records().isEmpty)
    await store.shutdown()
  }

  @MainActor func testRealSessionEndSurvivesAgentEOFAndPersistsItsInternalTurn() async throws {
    let (store, server, root) = try await liveFixture(definitions([
      ("SessionEnd", #"printf 'ended' > "$PLUGIN_DATA/session-ended"; printf 'SESSION-END-ERROR\n' >&2; exit 1"#)],
      asynchronous: ["SessionEnd"]))
    defer { server.stop(); try? FileManager.default.removeItem(at: root) }
    store.draft = "Session shutdown history"; await store.sendDraft()
    let task = try XCTUnwrap(store.selectedTask), id = try XCTUnwrap(task.runIDs.first)
    await store.modelTask(runID: id)?.value
    let before = try XCTUnwrap(store.library.chatRuns.first { $0.id == id })
    XCTAssertEqual(before.status, "succeeded")
    XCTAssertTrue(before.codexHookRuns.isEmpty)
    await store.shutdown()
    let marker = FileManager.default.enumerator(at: store.dataRoot.appendingPathComponent("Hooks/PluginData"),
      includingPropertiesForKeys: nil)?.allObjects.compactMap { $0 as? URL }
      .first { $0.lastPathComponent == "session-ended" }
    XCTAssertNotNil(marker, "The actual SessionEnd command must run, even when configured async")
    let result = try XCTUnwrap(store.library.chatRuns.first { $0.id == id })
    let end = try XCTUnwrap(result.codexHookRuns.first { $0.eventName == "session_end" }, result.result?.pretty ?? "")
    XCTAssertEqual(end.status, "failed")
    XCTAssertEqual(end.scope, "thread")
    XCTAssertNotNil(end.runtimeTurnID)
    XCTAssertNotEqual(end.runtimeTurnID, result.result?["codex_turn_id"].text)
    XCTAssertTrue(end.visibleEntries.contains { $0.text.contains("SESSION-END-ERROR") })
    XCTAssertEqual(result.codexHookStats?.errorCount, 1)
    XCTAssertEqual(result.result?["response"], before.result?["response"])
    let restored = WorkspaceStore(dataRoot: store.dataRoot); await restored.restore()
    XCTAssertEqual(restored.library.chatRuns.first { $0.id == id }?.codexHookRuns, result.codexHookRuns)
    await restored.shutdown()
  }

  @MainActor func testThreadLifecycleCannotAttachToPendingNewServiceOrUnknownThread() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("hook-end-history-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); await store.restore(); await store.openProjectless()
    let taskID = UUID().uuidString
    store.library.tasks.append(.init(id: taskID, project: "", title: "Old session", runIDs: ["run", "pending"]))
    let index = try XCTUnwrap(store.library.tasks.firstIndex { $0.id == taskID })
    store.library.tasks[index].codexThreadID = "new-thread"
    store.library.chatRuns = [try run(), AgentRun(id: "pending", kind: "chat", project: "", status: "running",
      createdAt: 3, updatedAt: 3, request: .object([:]), result: nil)]
    var ending = hook("end", event: "session_end"); ending.scope = "thread"
    let completed = try event(ending, turn: "internal-shutdown")
    store.recordCodexHook(taskID: taskID, threadID: "thread", event: completed)
    store.recordCodexHook(taskID: taskID, threadID: "thread", event: completed)
    XCTAssertEqual(store.library.chatRuns[0].codexHookRuns.count, 1)
    XCTAssertEqual(store.library.chatRuns[0].codexHookRuns.first?.runtimeTurnID, "internal-shutdown")
    XCTAssertTrue(store.library.chatRuns[1].codexHookRuns.isEmpty)
    store.recordCodexHook(runID: "pending", taskID: taskID, threadID: "thread", event: completed)
    store.recordCodexHook(taskID: taskID, threadID: "unknown", event: completed)
    ending.scope = "turn"
    store.recordCodexHook(taskID: taskID, threadID: "thread", event: try event(ending, turn: "unbound"))
    XCTAssertEqual(store.library.chatRuns[0].codexHookRuns.count, 1)
    XCTAssertTrue(store.library.chatRuns[1].codexHookRuns.isEmpty)
    await store.shutdown()
  }

  @MainActor func testRealSessionEndExplicitStopAndServiceChangeKeepOriginalRun() async throws {
    let (store, server, root) = try await liveFixture(definitions([("SessionEnd", "exit 0")]))
    defer { server.stop(); try? FileManager.default.removeItem(at: root) }
    store.draft = "First session"; await store.sendDraft()
    let task = try XCTUnwrap(store.selectedTask), first = try XCTUnwrap(task.runIDs.first)
    await store.modelTask(runID: first)?.value
    await store.codexTransport.stop(taskID: task.id)
    for _ in 0..<100 {
      if store.library.chatRuns.first(where: { $0.id == first })?.codexHookStats?.count == 1 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(store.library.chatRuns.first { $0.id == first }?.codexHookRuns.map(\.status), ["completed"])
    let secondStarted = await store.startChat("Resumed session", taskID: task.id)
    let second = try XCTUnwrap(secondStarted)
    await store.modelTask(runID: second)?.value
    var config = server.config; config.baseURL = config.baseURL.replacingOccurrences(of: "127.0.0.1", with: "localhost")
    try store.saveModelConfiguration(config)
    let thirdStarted = await store.startChat("Changed service", taskID: task.id)
    let third = try XCTUnwrap(thirdStarted)
    await store.modelTask(runID: third)?.value
    XCTAssertEqual(store.library.chatRuns.first { $0.id == first }?.codexHookStats?.count, 1)
    XCTAssertEqual(store.library.chatRuns.first { $0.id == second }?.codexHookRuns.map(\.status), ["completed"])
    XCTAssertTrue(store.library.chatRuns.first { $0.id == third }?.codexHookRuns.isEmpty == true)
    await store.shutdown()
    XCTAssertEqual(store.library.chatRuns.first { $0.id == third }?.codexHookRuns.map(\.status), ["completed"])
    XCTAssertEqual(try server.records().count, 3)
  }

  @MainActor func testRealSessionEndTimeoutIsRecordedBeforeAgentExit() async throws {
    let (store, server, root) = try await liveFixture(definitions([
      ("SessionEnd", #"touch "$PLUGIN_DATA/end-started"; sleep 5; touch "$PLUGIN_DATA/end-finished""#)]))
    defer { server.stop(); try? FileManager.default.removeItem(at: root) }
    store.draft = "Timeout on shutdown"; await store.sendDraft()
    let id = try XCTUnwrap(store.selectedTask?.runIDs.first)
    await store.modelTask(runID: id)?.value
    await store.shutdown()
    let end = try XCTUnwrap(store.library.chatRuns.first { $0.id == id }?.codexHookRuns.first)
    XCTAssertEqual(end.eventName, "session_end"); XCTAssertEqual(end.status, "failed")
    XCTAssertTrue(end.visibleEntries.contains { $0.kind == "error" && !$0.text.isEmpty })
    let markers = FileManager.default.enumerator(at: store.dataRoot.appendingPathComponent("Hooks/PluginData"),
      includingPropertiesForKeys: nil)?.allObjects.compactMap { ($0 as? URL)?.lastPathComponent } ?? []
    XCTAssertTrue(markers.contains("end-started")); XCTAssertFalse(markers.contains("end-finished"))
  }

  @MainActor func testRealShutdownStartsIndependentSessionEndHooksTogether() async throws {
    let command = #"mktemp "$PLUGIN_DATA/ready.XXXXXX" >/dev/null; while [ "$(ls "$PLUGIN_DATA"/ready.* | wc -l)" -lt 2 ]; do sleep 0.02; done"#
    for sharedProject in [false, true] {
      let (store, server, root) = try await liveFixture(definitions([("SessionEnd", command)], timeout: 3))
      defer { server.stop(); try? FileManager.default.removeItem(at: root) }
      if sharedProject {
        let project = root.appendingPathComponent("Project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        await store.open(project)
        XCTAssertTrue(store.connected, store.error ?? "")
      }
      store.draft = "First independent session"; await store.sendDraft()
      let first = try XCTUnwrap(store.selectedTask?.runIDs.first)
      await store.modelTask(runID: first)?.value
      store.newTask()
      let secondStarted = await store.startChat("Second independent session")
      let second = try XCTUnwrap(secondStarted)
      await store.modelTask(runID: second)?.value
      await store.shutdown()
      for id in [first, second] {
        let end = try XCTUnwrap(store.library.chatRuns.first { $0.id == id }?.codexHookRuns.first)
        XCTAssertEqual(end.eventName, "session_end")
        XCTAssertEqual(end.status, "completed", "Both real shell handlers must start before either can complete: \(end.entries)")
      }
    }
  }
}
