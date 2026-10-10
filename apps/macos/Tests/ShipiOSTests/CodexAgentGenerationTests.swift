import XCTest
@testable import ShipiOS

final class CodexAgentGenerationTests: XCTestCase {
  @MainActor func testRetiredAgentEventsCannotCorruptReconnectedTask() async throws {
    try await checkRetiredAgent(mode: "events")
  }

  @MainActor func testRetiredAgentGapCannotDisconnectReplacement() async throws {
    try await checkRetiredAgent(mode: "gap")
  }

  @MainActor func testRetiredAgentProtocolFailureCannotDisconnectReplacement() async throws {
    try await checkRetiredAgent(mode: "disconnect")
  }

  @MainActor private func checkRetiredAgent(mode: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-generation-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try mode.write(to: root.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
    let executable = root.appendingPathComponent("fixture-agent")
    try #"""
    #!/usr/bin/python3
    import sys, json, threading, pathlib, time
    root = pathlib.Path(__file__).parent
    mode = (root / "mode").read_text()
    count_file = root / "launch-count"
    generation = 0
    if "CodexAgents" in " ".join(sys.argv):
        generation = int(count_file.read_text()) + 1 if count_file.exists() else 1
        count_file.write_text(str(generation))
    lock = threading.Lock()
    workers = []
    def send(value):
        with lock: print(json.dumps(value), flush=True)
    def event(task, kind, **fields):
        send({"jsonrpc":"2.0", "method":"codex.event", "params":{
            "taskId":task, "threadId":"00000000-0000-4000-8000-000000000001",
            "event":dict(fields, type=kind, turn_id="turn-"+str(generation))}})
    def gap():
        send({"jsonrpc":"2.0", "method":"events.gap", "params":{"source":"codex"}})
    def retired(task):
        time.sleep(.05)
        event(task, "agent_message_delta", delta="BEFORE_GAP")
        gap()
        deadline = time.monotonic() + 4
        while not (root / "second-active").exists() and time.monotonic() < deadline:
            time.sleep(.01)
        if not (root / "second-active").exists(): return
        if mode == "events":
            event(task, "agent_message_delta", delta="OLD_LATE")
            event(task, "error", message="OLD_LATE_ERROR")
        elif mode == "disconnect":
            with lock: print("malformed protocol frame", flush=True)
        else: gap()
        (root / "late-events-sent").write_text(mode)
    def current(task):
        (root / "second-active").write_text("ready")
        deadline = time.monotonic() + 4
        while not (root / "late-events-sent").exists() and time.monotonic() < deadline:
            time.sleep(.01)
        time.sleep(.1)
        event(task, "task_complete", last_agent_message="NEW_ONLY")
    for line in sys.stdin:
        request = json.loads(line); method = request["method"]; p = request.get("params", {})
        result = {"protocolVersion":1} if method == "initialize" else {}
        if method == "codex.thread.start":
            result = {"threadId":"00000000-0000-4000-8000-000000000001", "resumed":False}
        if method == "codex.turn.submit":
            send({"jsonrpc":"2.0", "id":request["id"], "result":{"turnId":"turn-"+str(generation)}})
            event(p["taskId"], "task_started")
            worker = threading.Thread(target=retired if generation == 1 else current, args=(p["taskId"],))
            workers.append(worker); worker.start()
            continue
        send({"jsonrpc":"2.0", "id":request["id"], "result":result})
    # Keep stdout open after EOF to reproduce the production client's final drain.
    for worker in workers: worker.join(5)
    """#.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"), agentExecutable: executable)
    await store.restore(); await store.open(root)
    var config = ModelConfiguration(); config.apiProtocol = .codexResponses
    config.baseURL = "http://127.0.0.1:1/v1"; config.model = "gpt-5.4"
    try store.saveModelConfiguration(config); store.notificationPreferences = .init(timing: .never)
    let firstStarted = await store.startChat("first held turn")
    let first = try XCTUnwrap(firstStarted)
    let owner = try XCTUnwrap(store.library.task(containing: first)?.id)
    await store.modelTask(runID: first)?.value
    let failed = try XCTUnwrap(store.library.chatRuns.first { $0.id == first })
    XCTAssertEqual(failed.status, "failed")
    XCTAssertEqual(failed.result?["response"].text, "BEFORE_GAP")
    let secondStarted = await store.startChat("retry same task", taskID: owner)
    let second = try XCTUnwrap(secondStarted)
    await store.modelTask(runID: second)?.value
    let continued = try XCTUnwrap(store.library.chatRuns.first { $0.id == second })
    XCTAssertEqual(continued.status, "succeeded", continued.result?["message"].text ?? "")
    XCTAssertEqual(continued.result?["response"].text, "NEW_ONLY")
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("launch-count")), "2")
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("late-events-sent")), mode)
    XCTAssertNil(store.codexTransport.turnToken(taskID: owner))
    await store.shutdown()
  }
}
