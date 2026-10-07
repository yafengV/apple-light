import XCTest
@testable import ShipiOS

final class SubagentOverviewPreviewTests: XCTestCase {
  private func agent(_ status: CodexSubagentStatus = .completed, objective: String? = nil) -> CodexSubagent {
    .init(rootThreadID: "root", threadID: "child", status: status, loaded: true,
      preview: "Last reply must stay in history", observedAtMs: 999, objective: objective)
  }
  func testObjectiveReplacesFinalReplyAndMissingDoneBriefDoesNotShowOldOutput() {
    XCTAssertEqual(SubagentOverviewPreview.text(for: agent(objective: "# **Inspect** [files](https://example.test)\n\n- `Swift`")), "Inspect files Swift")
    XCTAssertNil(SubagentOverviewPreview.text(for: agent()))
    XCTAssertEqual(SubagentOverviewPreview.text(for: agent(.running)), "正在工作")
    XCTAssertEqual(SubagentOverviewPreview.text(for: agent(.pendingInit)), "正在工作")
    XCTAssertEqual(SubagentOverviewPreview.objectiveText("<script>private script</script>\n\n检查🙂"), "检查🙂")
    XCTAssertNil(SubagentOverviewPreview.objectiveText("  \n\t"))
  }
  func testBriefLimitKeepsWhitespaceAndUnicodeValid() {
    XCTAssertEqual(SubagentOverviewPreview.objectiveText(String(repeating: "x", count: 60)), String(repeating: "x", count: 60))
    XCTAssertEqual(SubagentOverviewPreview.objectiveText(String(repeating: "x", count: 61)), String(repeating: "x", count: 59) + "…")
    XCTAssertEqual(SubagentOverviewPreview.objectiveText(String(repeating: "中", count: 58) + "🙂尾"), String(repeating: "中", count: 58) + "…")
    XCTAssertEqual(SubagentOverviewPreview.objectiveText("a \n\t b"), "a b")
  }
  func testOnlyCurrentActivePublicReasoningCanSupplyFallback() throws {
    let events: [JSONValue] = try [
      ##"{"type":"task_started","turn_id":"old"}"##,
      ##"{"type":"agent_reasoning","text":"Old completed summary"}"##,
      ##"{"type":"task_complete","turn_id":"old"}"##,
      ##"{"type":"task_started","turn_id":"new"}"##,
      ##"{"type":"agent_reasoning_raw_content","text":"Private raw reasoning"}"##,
      ##"{"type":"reasoning_content_delta","turn_id":"new","item_id":"r","summary_index":0,"delta":"# **I’m Inspecting** "}"##,
      ##"{"type":"reasoning_content_delta","turn_id":"new","item_id":"r","summary_index":0,"delta":"files."}"##
    ].map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    XCTAssertEqual(SubagentOverviewPreview.text(for: agent(.running), liveEvents: events), "inspecting files")
    XCTAssertEqual(SubagentOverviewPreview.text(for: agent(.running, objective: "Delegated brief"), liveEvents: events), "Delegated brief")
    XCTAssertNil(SubagentOverviewPreview.text(for: agent(), liveEvents: events))
    XCTAssertEqual(SubagentOverviewPreview.text(for: agent(.pendingInit), liveEvents: events), "正在工作")
    let ended = events + [try JSONDecoder().decode(JSONValue.self, from: Data(##"{"type":"turn_aborted","turn_id":"new"}"##.utf8))]
    XCTAssertEqual(SubagentOverviewPreview.text(for: agent(.running), liveEvents: ended), "正在工作")
    XCTAssertEqual(SubagentOverviewPreview.text(for: agent(.running), liveEvents: Array(events.prefix(5))), "正在工作")
  }
  func testObjectiveRoundTripsOptionalWireAndOldPersistence() throws {
    let row = agent(objective: "检查🙂")
    XCTAssertEqual(try JSONDecoder().decode(CodexSubagent.self, from: JSONEncoder().encode(row)).objective, "检查🙂")
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
    object.removeValue(forKey: "objective")
    XCTAssertNil(try JSONDecoder().decode(CodexSubagent.self, from: JSONSerialization.data(withJSONObject: object)).objective)
    var assembler = CodexSubagentSnapshotAssembler()
    let event: JSONValue = .object(["type": .string("shipios_subagent_snapshot"), "snapshotId": .string(UUID().uuidString),
      "offset": .number(0), "total": .number(1), "revision": .number(1), "observedAtMs": .number(1), "done": .bool(true),
      "agents": .array([.object(["threadId": .string(UUID().uuidString), "status": .string("completed"), "loaded": .bool(false), "objective": .string("检查🙂")])])])
    XCTAssertEqual(try XCTUnwrap(assembler.append(event, root: UUID().uuidString)).first?.objective, "检查🙂")
  }
}
