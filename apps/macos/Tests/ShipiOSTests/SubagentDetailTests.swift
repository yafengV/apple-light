import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class SubagentDetailTests: XCTestCase {
  private func agent(_ id: String = "child", loaded: Bool = true) -> CodexSubagent {
    .init(rootThreadID: "root", threadID: id, nickname: "Worker", model: "fixture",
      status: .completed, loaded: loaded, observedAtMs: 0)
  }
  private func events(_ source: String) throws -> [JSONValue] {
    try JSONDecoder().decode([JSONValue].self, from: Data(source.utf8))
  }

  func testLegacyAndRawMessagesDoNotDuplicateAndToolOutputKeepsAssociation() throws {
    let transcript = SubagentTranscript(events: try events("""
      [{"type":"raw_response_item","item":{"type":"message","role":"user","content":[{"text":"question"}]}},
       {"type":"user_message","message":"question"},
       {"type":"raw_response_item","item":{"type":"function_call","name":"build","call_id":"call","arguments":"swift build"}},
       {"type":"raw_response_item","item":{"type":"function_call_output","call_id":"call","output":"failed compiler"}},
       {"type":"raw_response_item","item":{"type":"message","role":"assistant","content":[{"text":"answer"}]}},
       {"type":"agent_message","message":"answer"}]
      """))
    XCTAssertEqual(transcript.entries.map(\.kind), [.user, .tool, .tool, .assistant])
    XCTAssertEqual(transcript.entries.map(\.text), ["question", "swift build", "failed compiler", "answer"])
    XCTAssertEqual(transcript.entries.filter { $0.kind == .tool }.map(\.title), ["build", "build"])
  }

  func testNativeTurnItemsPreserveTextAndOnlyPublicReasoningSummary() throws {
    let transcript = SubagentTranscript(events: try events("""
      [{"type":"item_completed","item":{"type":"UserMessage","content":[{"text":"question"}]}},
       {"type":"item_completed","item":{"type":"Reasoning","summary_text":["public summary"],"raw_content":["private reasoning"]}},
       {"type":"item_completed","item":{"type":"CommandExecution","command":["swift","test"],"aggregated_output":"complete"}},
       {"type":"item_completed","item":{"type":"AgentMessage","content":[{"text":"first"},{"text":"second"}]}},
       {"type":"raw_response_item","item":{"type":"reasoning","summary":[{"text":"another summary"}],"content":[{"text":"private raw"}]}}]
      """))
    XCTAssertEqual(transcript.entries.map(\.text), ["question", "public summary", "complete", "first\nsecond", "another summary"])
    XCTAssertFalse(transcript.entries.contains { $0.text.contains("private") })
  }

  func testStaleTerminalCannotClearNewChildTurn() throws {
    var transcript = SubagentTranscript(events: try events("""
      [{"type":"task_started","turn_id":"old"},{"type":"task_complete","turn_id":"old"},
       {"type":"task_started","turn_id":"new"},{"type":"turn_aborted","turn_id":"old"}]
      """))
    XCTAssertEqual(transcript.activeTurnID, "new")
    transcript = SubagentTranscript(events: try events("""
      [{"type":"task_started","turn_id":"new"},{"type":"task_complete","turn_id":"new"}]
      """))
    XCTAssertNil(transcript.activeTurnID)
  }

  func testSelectionChangeDuringHistoryReadDiscardsOldResult() async {
    let state = SubagentDetailState(); state.select(agent("first"))
    await state.load { selected in
      XCTAssertEqual(selected.threadID, "first")
      state.select(self.agent("second")); state.draft = "new draft"
      return [.object(["type": .string("agent_message"), "message": .string("old answer")])]
    }
    XCTAssertEqual(state.selected?.threadID, "second")
    XCTAssertTrue(state.transcript.entries.isEmpty)
    XCTAssertEqual(state.draft, "new draft"); XCTAssertFalse(state.loading)
  }

  func testReadFailureRetainsHistoryAndRetryClearsError() async {
    let state = SubagentDetailState(); state.select(agent())
    let record: [JSONValue] = [.object(["type": .string("agent_message"), "message": .string("answer")])]
    await state.load { _ in record }
    await state.load { _ in throw AgentFailure(message: "History unavailable") }
    XCTAssertEqual(state.transcript.entries.first?.text, "answer")
    XCTAssertNotNil(state.error); XCTAssertFalse(state.loading)
    await state.load { _ in record }; XCTAssertNil(state.error)
  }

  func testMetadataRefreshPreservesDraftAndBackClearsWindowState() async {
    let first = SubagentDetailState(), second = SubagentDetailState()
    first.select(agent(loaded: false)); second.select(agent())
    first.draft = "first window"; second.draft = "second window"
    first.update(agent()); XCTAssertTrue(first.selected?.loaded == true)
    first.update(agent("foreign")); XCTAssertEqual(first.selected?.threadID, "child")
    XCTAssertEqual(first.draft, "first window")
    first.select(nil)
    XCTAssertNil(first.selected); XCTAssertTrue(first.draft.isEmpty)
    XCTAssertEqual(second.draft, "second window")
  }

  func testSteeringUsesCapturedChildAndTurnAndDoesNotClearEditedDraft() async throws {
    let state = SubagentDetailState(); state.select(agent()); state.draft = "steer"
    await state.load { _ in try self.events("[{\"type\":\"task_started\",\"turn_id\":\"actual\"}]") }
    let sent = await state.send(working: true) { selected, text, turn in
      XCTAssertEqual(selected.threadID, "child"); XCTAssertEqual(text, "steer"); XCTAssertEqual(turn, "actual")
      state.draft = "next draft"
      return "actual"
    }
    XCTAssertTrue(sent); XCTAssertEqual(state.draft, "next draft"); XCTAssertFalse(state.sending)
  }

  func testFailedSendRetainsDraftAndOldSendCannotMutateNewSelection() async {
    let state = SubagentDetailState(); state.select(agent()); state.draft = "retry me"
    let failed = await state.send(working: false) { _, _, _ in throw AgentFailure(message: "Disconnected") }
    XCTAssertFalse(failed); XCTAssertEqual(state.draft, "retry me"); XCTAssertNotNil(state.error)
    let old = await state.send(working: false) { _, _, turn in
      XCTAssertNil(turn); state.select(self.agent("new")); state.draft = "new draft"
      return "old"
    }
    XCTAssertFalse(old); XCTAssertEqual(state.selected?.threadID, "new")
    XCTAssertEqual(state.draft, "new draft"); XCTAssertFalse(state.sending); XCTAssertNil(state.error)
  }

  func testColdAndUnknownWorkingTurnCannotSubmit() async {
    let state = SubagentDetailState(); state.select(agent(loaded: false)); state.draft = "text"
    var calls = 0
    let submit: (CodexSubagent, String, String?) async throws -> String = { _, _, _ in calls += 1; return "turn" }
    let cold = await state.send(working: false, using: submit)
    state.update(agent())
    let unknown = await state.send(working: true, using: submit)
    XCTAssertFalse(cold); XCTAssertFalse(unknown); XCTAssertEqual(calls, 0)
    for status in [CodexSubagentStatus.shutdown, .notLoaded] {
      var closed = agent(); closed.status = status
      state.update(closed)
      let sent = await state.send(working: false, using: submit)
      XCTAssertFalse(sent)
    }
    XCTAssertEqual(calls, 0, "A loaded but shut down thread cannot accept new input")
  }

  func testCancellationReleasesBusyFlagsWithoutDroppingDraft() async {
    let state = SubagentDetailState(); state.select(agent()); state.draft = "keep"
    let send = Task { await state.send(working: false) { _, _, _ in
      try await Task.sleep(for: .seconds(30)); return "turn"
    } }
    while !state.sending { await Task.yield() }
    send.cancel(); _ = await send.value
    XCTAssertFalse(state.sending); XCTAssertEqual(state.draft, "keep"); XCTAssertNil(state.error)
    let load = Task { await state.load { _ in try await Task.sleep(for: .seconds(30)); return [] } }
    while !state.loading { await Task.yield() }
    load.cancel(); await load.value
    XCTAssertFalse(state.loading); XCTAssertNil(state.error)
  }

  func testNativeTranscriptLayoutAtNarrowAndWideSizesKeepsLongHistory() throws {
    let long = String(repeating: "完整子会话记录🙂 ", count: 20_000)
    let transcript = SubagentTranscript(events: [.object(["type": .string("agent_message"), "message": .string(long)])])
    XCTAssertEqual(transcript.entries.first?.text, long)
    for width in [360.0, 760.0] {
      let view = NSHostingView(rootView: SubagentTranscriptView(transcript: transcript,
        loading: false, error: "Reload required", retry: {}, openLink: { _ in }))
      view.frame = NSRect(x: 0, y: 0, width: width, height: 600)
      view.layoutSubtreeIfNeeded()
      XCTAssertEqual(view.bounds.width, width)
      XCTAssertGreaterThan(view.fittingSize.height, 0)
    }
  }
}
