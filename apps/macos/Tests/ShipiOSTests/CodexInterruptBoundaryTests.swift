import XCTest
@testable import ShipiOS

final class CodexInterruptBoundaryTests: XCTestCase {
  @MainActor func testDelayedTerminalCoalescesStopAndOldCancellationCannotTouchNextTurn() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("interrupt-boundary-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("fixture-agent")
    try #"""
    #!/usr/bin/python3
    import sys, json, threading, os
    lock = threading.Lock()
    count = 0
    interrupts = 0
    def send(value):
        with lock: print(json.dumps(value), flush=True)
    def event(task, turn, kind, **fields):
        send({"jsonrpc":"2.0","method":"codex.event","params":{"taskId":task,
            "threadId":"00000000-0000-4000-8000-000000000001",
            "event":dict(fields,type=kind,turn_id=turn)}})
    for line in sys.stdin:
        request=json.loads(line); method=request["method"]; p=request.get("params",{})
        result={"protocolVersion":1} if method=="initialize" else {}
        if method=="codex.thread.start": result={"threadId":"00000000-0000-4000-8000-000000000001","resumed":False}
        if method=="codex.turn.submit":
            count+=1; task=p["taskId"]; turn="turn-"+str(count)
            send({"jsonrpc":"2.0","id":request["id"],"result":{"turnId":turn}})
            event(task,turn,"task_started")
            if count>1:
                threading.Timer(.4,lambda task=task,turn=turn: event(task,turn,"task_complete",last_agent_message="continued")).start()
            continue
        if method=="codex.turn.interrupt":
            interrupts+=1
            with open(os.path.join(os.path.dirname(__file__),"interrupt-count.txt"),"w") as file: file.write(str(interrupts))
            # Submission ack precedes the actual native lifecycle boundary.
            threading.Timer(.4,lambda task=task,turn=turn: event(task,turn,"turn_aborted",reason="interrupted")).start()
        send({"jsonrpc":"2.0","id":request["id"],"result":result})
    """#.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"), agentExecutable: executable)
    await store.restore(); await store.open(root)
    var config = ModelConfiguration(); config.apiProtocol = .codexResponses
    config.baseURL = "http://127.0.0.1:1/v1"; config.model = "gpt-5.4"
    try store.saveModelConfiguration(config); store.notificationPreferences = .init(timing: .never)
    let firstStarted = await store.startChat("first held turn")
    let first = try XCTUnwrap(firstStarted), owner = try XCTUnwrap(store.library.task(containing: first)?.id)
    let running = try XCTUnwrap(store.modelTask(runID: first))
    for _ in 0..<300 {
      if store.codexTransport.canSteer(taskID: owner) { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let oldToken = try XCTUnwrap(store.codexTransport.turnToken(taskID: owner))
    let began = ContinuousClock.now
    let explicit = Task { await store.codexTransport.interrupt(taskID: owner, expectedToken: oldToken) }
    await store.cancel(taskID: owner)
    await running.value; await explicit.value
    XCTAssertGreaterThanOrEqual(began.duration(to: .now), .milliseconds(350))
    XCTAssertEqual(store.library.chatRuns.first { $0.id == first }?.status, "cancelled")
    XCTAssertNil(store.codexTransport.turnToken(taskID: owner))
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("interrupt-count.txt")), "1")
    let secondStarted = await store.startChat("immediate continuation", taskID: owner)
    let second = try XCTUnwrap(secondStarted)
    for _ in 0..<300 {
      if store.codexTransport.canSteer(taskID: owner) { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(store.codexTransport.canSteer(taskID: owner))
    XCTAssertNotEqual(store.codexTransport.turnToken(taskID: owner), oldToken)
    await store.codexTransport.interrupt(taskID: owner, expectedToken: oldToken)
    await store.modelTask(runID: second)?.value
    let continued = try XCTUnwrap(store.library.chatRuns.first { $0.id == second })
    XCTAssertEqual(continued.status, "succeeded", continued.result?["message"].text ?? "")
    XCTAssertEqual(continued.result?["response"].text, "continued")
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("interrupt-count.txt")), "1")
    await store.shutdown()
  }
}
