import XCTest
@testable import ShipiOS

final class SubagentHistoryTransportTests: XCTestCase {
  @MainActor func testImmutablePagesRejectForeignMixedCorruptAndNonprogressingHistory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("child-history-wire-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("fixture-agent")
    try #"""
    #!/usr/bin/python3
    import sys,json,hashlib,uuid
    root="00000000-0000-4000-8000-000000000001"
    snapshot="00000000-0000-4000-8000-000000000004"
    body=json.dumps([{"type":"agent_message","message":"complete child"}],ensure_ascii=False)
    def send(value): print(json.dumps(value),flush=True)
    for line in sys.stdin:
        request=json.loads(line); method=request["method"]; p=request.get("params",{})
        result={"protocolVersion":1} if method=="initialize" else {}
        if method=="codex.thread.start": result={"threadId":root,"resumed":False}
        if method=="codex.turn.submit":
            send({"jsonrpc":"2.0","id":request["id"],"result":{"turnId":"parent"}})
            send({"jsonrpc":"2.0","method":"codex.event","params":{"taskId":p["taskId"],"threadId":root,
                "event":{"type":"task_complete","turn_id":"parent","last_agent_message":"parent reply"}}})
            continue
        if method=="codex.subagent.history.read":
            mode=p["childThreadId"]; offset=p["offset"]
            content="{}" if mode=="bad-json" else body
            end=min(offset+7,len(content)); chunk=content[offset:end]
            result={"rootThreadId":root,"childThreadId":mode,"snapshotId":snapshot,
                "offset":offset,"nextOffset":end,"totalBytes":len(content),"chunk":chunk,
                "sha256":hashlib.sha256(content.encode()).hexdigest(),"done":end==len(content)}
            if mode=="foreign-root": result["rootThreadId"]=str(uuid.uuid4())
            if mode=="foreign-child": result["childThreadId"]="peer"
            if mode=="bad-hash": result["sha256"]="0"*64
            if mode=="bad-offset": result["offset"]+=1
            if mode=="bad-snapshot" and offset>0: result["snapshotId"]=str(uuid.uuid4())
            if mode=="bad-total" and offset>0: result["totalBytes"]+=1
            if mode=="missing-chunk": result.pop("chunk")
            if mode=="stalled": result.update(chunk="",nextOffset=offset,done=False)
        send({"jsonrpc":"2.0","id":request["id"],"result":result})
    """#.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"), agentExecutable: executable)
    await store.restore(); await store.openProjectless()
    addTeardownBlock { await store.shutdown() }
    var config = ModelConfiguration(); config.apiProtocol = .codexResponses
    config.baseURL = "http://127.0.0.1:1/v1"; config.model = "gpt-5.4"
    try store.saveModelConfiguration(config); store.notificationPreferences = .init(timing: .never)
    let started = await store.startChat("Parent")
    let run = try XCTUnwrap(started), owner = try XCTUnwrap(store.library.task(containing: run)?.id)
    await store.modelTask(runID: run)?.value
    let thread = try XCTUnwrap(store.library.tasks.first { $0.id == owner }?.codexThreadID)
    XCTAssertEqual(store.library.chatRuns.first { $0.id == run }?.status, "succeeded")
    let good = try await store.codexTransport.readSubagentHistory(taskID: owner, rootThreadID: thread, childThreadID: "good")
    XCTAssertEqual(SubagentTranscript(events: good).entries.first?.text, "complete child")
    for mode in ["foreign-root", "foreign-child", "bad-hash", "bad-offset", "bad-snapshot", "bad-total", "missing-chunk", "stalled", "bad-json"] {
      do {
        _ = try await store.codexTransport.readSubagentHistory(taskID: owner, rootThreadID: thread, childThreadID: mode)
        XCTFail("Malformed history accepted: \(mode)")
      } catch { XCTAssertFalse(error.localizedDescription.isEmpty, mode) }
    }
    let after = try await store.codexTransport.readSubagentHistory(taskID: owner, rootThreadID: thread, childThreadID: "good")
    XCTAssertEqual(after, good, "Failed reads must not contaminate another snapshot")
    XCTAssertEqual(store.library.chatRuns.first { $0.id == run }?.result?["response"].text, "parent reply")
    await store.shutdown()
  }
}
