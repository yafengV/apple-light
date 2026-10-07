import XCTest
@testable import ShipiOS

final class SubagentOverviewProjectionTests: XCTestCase {
  func testColdDiscoveredThreadIsDoneWithoutInventingLiveInput() {
    let cold = CodexSubagent(rootThreadID: "root", threadID: "cold", status: .notLoaded,
      loaded: false, observedAtMs: 0)
    let overview = SubagentOverview([cold])
    XCTAssertTrue(overview.active.isEmpty)
    XCTAssertEqual(overview.done.map(\.id), [cold.id])
    XCTAssertFalse(cold.working); XCTAssertFalse(cold.acceptsInput)
    XCTAssertEqual(cold.status, .notLoaded)
  }
}

extension SubagentOverviewProjectionTests {
  func testWaitingIsSeparateFromRunningAndPollingNeverChangesRecencyOrder() {
    func agent(_ id: String, _ status: CodexSubagentStatus, _ recency: Int?, poll: Int = 0) -> CodexSubagent {
      .init(rootThreadID: "root", threadID: id, status: status, loaded: status != .notLoaded,
        observedAtMs: poll, recencyAtMs: recency)
    }
    let rows = [agent("old-active", .running, 1, poll: 900), agent("waiting", .pendingInit, 4),
      agent("new-done", .completed, 8), agent("cold", .notLoaded, 8),
      agent("legacy", .completed, nil, poll: 1000), agent("failed", .failed, 100),
      agent("stopped", .interrupted, 101), agent("closed", .shutdown, 102)]
    let projection = SubagentOverview(rows)
    XCTAssertEqual(projection.visible.map(\.threadID), ["new-done", "cold", "waiting", "old-active", "legacy"])
    XCTAssertEqual(projection.active.map(\.threadID), ["waiting", "old-active"])
    XCTAssertEqual(projection.running.map(\.threadID), ["old-active"])
    XCTAssertEqual(projection.waiting.map(\.threadID), ["waiting"])
    XCTAssertEqual(projection.done.map(\.threadID), ["new-done", "cold", "legacy"])
    XCTAssertTrue(rows[1].working, "Overview waiting must not change native cancellation semantics")
    var restored = rows[0]; restored.disconnect()
    XCTAssertEqual(restored.overviewStatus, .done)
    XCTAssertEqual(restored.recencyAtMs, 1)
    XCTAssertFalse(restored.working)
  }

  func testLegacyPersistenceAndWireKeepRecencyOptionalAndIndependentOfPolling() throws {
    let child = UUID().uuidString, root = UUID().uuidString
    var assembler = CodexSubagentSnapshotAssembler()
    let event: JSONValue = .object(["type": .string("shipios_subagent_snapshot"),
      "snapshotId": .string(UUID().uuidString), "offset": .number(0), "total": .number(1),
      "done": .bool(true), "revision": .number(1), "observedAtMs": .number(9999),
      "agents": .array([.object(["threadId": .string(child), "status": .string("completed"),
        "loaded": .bool(false), "recencyAtMs": .number(42)])])])
    let rows = try XCTUnwrap(assembler.append(event, root: root))
    XCTAssertEqual(rows[0].recencyAtMs, 42); XCTAssertEqual(rows[0].observedAtMs, 9999)
    let encoded = try JSONEncoder().encode(rows[0])
    XCTAssertEqual(try JSONDecoder().decode(CodexSubagent.self, from: encoded).recencyAtMs, 42)
    var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    legacy.removeValue(forKey: "recencyAtMs")
    XCTAssertNil(try JSONDecoder().decode(CodexSubagent.self, from: JSONSerialization.data(withJSONObject: legacy)).recencyAtMs)
  }
  func testNegativeRecencyRejectsSnapshotWithoutBecomingAVisibleRow() throws {
    let root = UUID().uuidString, child = UUID().uuidString
    let value = """
    {"type":"shipios_subagent_snapshot","snapshotId":"\(UUID().uuidString)",
    "offset":0,"total":1,"done":true,"revision":1,"observedAtMs":1,
    "agents":[{"threadId":"\(child)","status":"completed","loaded":false,"recencyAtMs":-1}]}
    """
    var assembler = CodexSubagentSnapshotAssembler()
    XCTAssertNil(assembler.append(try JSONDecoder().decode(JSONValue.self, from: Data(value.utf8)), root: root))
  }

}
