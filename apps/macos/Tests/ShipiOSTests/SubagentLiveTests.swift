import CryptoKit
import XCTest
@testable import ShipiOS

@MainActor final class SubagentLiveTests: XCTestCase {
  private func event(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
  }
  private func frames(_ event: JSONValue, child: String = "child", stream: String = UUID().uuidString,
    sequence: Int = 1, size: Int = 48 * 1024) throws -> [JSONValue] {
    let data = try JSONEncoder().encode(event)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    var offset = 0, frames: [JSONValue] = []
    while offset < data.count {
      var end = min(offset + size, data.count)
      while String(data: data[offset..<end], encoding: .utf8) == nil { end -= 1 }
      frames.append(.object(["type": .string("shipios_subagent_event"), "childThreadId": .string(child),
        "streamId": .string(stream), "sequence": .number(Double(sequence)), "eventId": .string("native"),
        "offset": .number(Double(offset)), "totalBytes": .number(Double(data.count)), "sha256": .string(digest),
        "done": .bool(end == data.count), "chunk": .string(String(data: data[offset..<end], encoding: .utf8)!)]))
      offset = end
    }
    return frames
  }
  private func changed(_ frame: JSONValue, _ key: String, _ value: JSONValue) -> JSONValue {
    guard case .object(var object) = frame else { return frame }
    object[key] = value; return .object(object)
  }

  func testLargeUnicodeEventIsAtomicAndCompletedDuplicateIsIgnored() throws {
    var state = SubagentLiveState()
    let message: JSONValue = .object(["type": .string("agent_message"), "message": .string(String(repeating: "中文🙂", count: 30000))])
    let parts = try frames(message)
    XCTAssertGreaterThan(parts.count, 1)
    for (index, part) in parts.enumerated() {
      state.append(part, child: "child")
      XCTAssertEqual(state.events.count, index == parts.count - 1 ? 1 : 0)
    }
    XCTAssertEqual(state.events, [message]); XCTAssertNil(state.error)
    for part in parts { state.append(part, child: "child") }
    XCTAssertEqual(state.events, [message])
  }

  func testBadIdentityMissingOffsetSequenceDigestAndMixedChunksNeverPublishPartialEvent() throws {
    let parts = try frames(event("{\"type\":\"agent_message\",\"message\":\"中文🙂 long message\"}"), size: 16)
    let invalid = [changed(parts[0], "childThreadId", .string("peer")),
      changed(parts[0], "sequence", .number(2)), changed(parts[0], "offset", .number(-1)),
      changed(parts[0], "done", .bool(true)), changed(parts[0], "streamId", .string("not-uuid"))]
    for part in invalid {
      var state = SubagentLiveState(); state.append(part, child: "child")
      XCTAssertTrue(state.events.isEmpty); XCTAssertNotNil(state.error)
    }
    for key in ["streamId", "eventId", "sha256", "totalBytes", "offset"] {
      var state = SubagentLiveState(); state.append(parts[0], child: "child")
      let replacement: JSONValue = key == "offset" || key == "totalBytes" ? .number(999) : .string(UUID().uuidString)
      state.append(changed(parts[1], key, replacement), child: "child")
      XCTAssertTrue(state.events.isEmpty); XCTAssertNotNil(state.error)
    }
    var damaged = SubagentLiveState()
    for part in parts { damaged.append(changed(part, "sha256", .string(String(repeating: "0", count: 64))), child: "child") }
    XCTAssertTrue(damaged.events.isEmpty); XCTAssertNotNil(damaged.error)
  }

  func testMissingEventAndRetiredStreamCannotReplaceCurrentChild() throws {
    let record = try event("{\"type\":\"agent_message\",\"message\":\"answer\"}")
    let old = UUID().uuidString, new = UUID().uuidString
    var state = SubagentLiveState()
    for frame in try frames(record, stream: old) { state.append(frame, child: "child") }
    for frame in try frames(record, stream: new) { state.append(frame, child: "child") }
    for frame in try frames(record, stream: old) { state.append(frame, child: "child") }
    XCTAssertEqual(state.events, [record]); XCTAssertNil(state.error)
    for frame in try frames(record, stream: new, sequence: 3) { state.append(frame, child: "child") }
    XCTAssertEqual(state.events, [record]); XCTAssertNotNil(state.error)
  }

  func testStoreRejectsPeerRootAndUnknownChildAndDoesNotPersistTransientEvents() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("child-live-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); defer { store.workspace.browser.shutdown() }
    let child = CodexSubagent(rootThreadID: "root", threadID: "child", status: .running, loaded: true, observedAtMs: 0)
    var task = WorkspaceTask(id: "owner", project: root.path, title: "Parent", runIDs: [])
    task.codexThreadID = "root"; task.codexSubagents = [child]
    store.library.tasks = [task]
    let frame = try frames(event("{\"type\":\"agent_message_content_delta\",\"thread_id\":\"child\",\"delta\":\"transient text\"}"))[0]
    for (owner, parent) in [("peer", "root"), ("owner", "peer-root")] {
      store.recordSubagentEvent(taskID: owner, threadID: parent, event: frame)
    }
    store.recordSubagentEvent(taskID: "owner", threadID: "root", event: changed(frame, "childThreadId", .string("peer-child")))
    XCTAssertTrue(store.subagentLiveStates.isEmpty)
    store.recordSubagentEvent(taskID: "owner", threadID: "root", event: frame)
    XCTAssertEqual(store.subagentLiveStates[child.id]?.events.count, 1)
    XCTAssertFalse(String(decoding: try JSONEncoder().encode(store.library), as: UTF8.self).contains("transient text"))
    store.recordCodexThreadID(taskID: "owner", threadID: UUID().uuidString)
    XCTAssertNil(store.subagentLiveStates[child.id])
  }

  func testCurrentTurnLiveReplacesMatchingHistoryAndRetainsPreCompactionPrefix() throws {
    let start = try event("{\"type\":\"task_started\",\"turn_id\":\"new\"}")
    let delta = try event("{\"type\":\"agent_message_content_delta\",\"turn_id\":\"new\",\"item_id\":\"item\",\"delta\":\"partial🙂\"}")
    var state = SubagentLiveState(); let stream = UUID().uuidString
    for (i, record) in [start, delta].enumerated() {
      for part in try frames(record, stream: stream, sequence: i + 1) { state.append(part, child: "child") }
    }
    let prefix = try event("{\"type\":\"agent_message\",\"message\":\"old full history\"}")
    let merged = state.merged(with: [prefix, start, delta])
    XCTAssertEqual(merged, [prefix, start, delta])
    let transcript = SubagentTranscript(events: merged)
    XCTAssertEqual(transcript.entries.map(\.text), ["old full history", "partial🙂"])
    XCTAssertEqual(transcript.activeTurnID, "new")
  }

  func testDurableFinalOrNewTurnCanOvertakeLiveWithoutRevertingVisibleHistory() throws {
    let start = try event("{\"type\":\"task_started\",\"turn_id\":\"turn\"}")
    let reply = try event("{\"type\":\"agent_message\",\"message\":\"complete\"}")
    let end = try event("{\"type\":\"task_complete\",\"turn_id\":\"turn\"}")
    var live = SubagentLiveState()
    for frame in try frames(start) { live.append(frame, child: "child") }
    XCTAssertEqual(live.merged(with: [start, reply, end]), [start, reply, end])
    let next = try event("{\"type\":\"task_started\",\"turn_id\":\"next\"}")
    XCTAssertEqual(live.merged(with: [start, reply, end, next]), [start, reply, end, next])
  }

  func testStreamingFinalReconcilesOnceAndOlderRawTurnsAreNotSuppressed() throws {
    let source = """
      [{"type":"task_started","turn_id":"old"},
       {"type":"raw_response_item","item":{"type":"message","role":"assistant","content":[{"text":"old raw"}]}},
       {"type":"task_complete","turn_id":"old"},{"type":"task_started","turn_id":"new"},
       {"type":"item_completed","item":{"type":"UserMessage","content":[{"text":"user"}]}},
       {"type":"user_message","message":"user"},
       {"type":"agent_message_content_delta","turn_id":"new","item_id":"item","delta":"part"},
       {"type":"agent_message_content_delta","turn_id":"old","item_id":"old","delta":"stale"},
       {"type":"agent_message_content_delta","turn_id":"new","item_id":"item","delta":"ial"},
       {"type":"item_completed","item":{"id":"item","type":"AgentMessage","content":[{"text":"partial complete"}]}},
       {"type":"agent_message","message":"partial complete"},{"type":"task_complete","turn_id":"new"}]
      """
    let transcript = SubagentTranscript(events: try JSONDecoder().decode([JSONValue].self, from: Data(source.utf8)))
    XCTAssertEqual(transcript.entries.map(\.text), ["old raw", "user", "partial complete"])
    XCTAssertNil(transcript.activeTurnID)
  }

  func testLiveUpdateDuringHistoryLoadPreservesLatestDeltaAndWindowDrafts() async throws {
    let agent = CodexSubagent(rootThreadID: "root", threadID: "child", status: .running, loaded: true, observedAtMs: 0)
    let state = SubagentDetailState(), other = SubagentDetailState()
    state.select(agent); other.select(agent); state.draft = "one"; other.draft = "two"
    let start = try event("{\"type\":\"task_started\",\"turn_id\":\"turn\"}")
    var live = SubagentLiveState(); let stream = UUID().uuidString
    for frame in try frames(start, stream: stream) { live.append(frame, child: "child") }
    state.updateLive(live); other.updateLive(live)
    let delta = try event("{\"type\":\"agent_message_content_delta\",\"turn_id\":\"turn\",\"item_id\":\"item\",\"delta\":\"newest\"}")
    await state.load { _ in
      for frame in try self.frames(delta, stream: stream, sequence: 2) { live.append(frame, child: "child") }
      state.updateLive(live); other.updateLive(live)
      return [start]
    }
    XCTAssertEqual(state.transcript.entries.map(\.text), ["newest"])
    XCTAssertEqual(other.transcript.entries.map(\.text), ["newest"])
    XCTAssertEqual(state.draft, "one"); XCTAssertEqual(other.draft, "two")
    state.select(nil); XCTAssertTrue(state.transcript.entries.isEmpty)
    XCTAssertEqual(other.transcript.entries.map(\.text), ["newest"])
  }
}
