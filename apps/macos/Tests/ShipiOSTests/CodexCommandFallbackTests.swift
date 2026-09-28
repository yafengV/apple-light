import XCTest
@testable import ShipiOS

final class CodexCommandFallbackTests: XCTestCase {
  private func call(id: String = "setup", name: String = "exec_command") -> JSONValue {
    .object(["type": .string("raw_response_item"), "item": .object([
      "type": .string("function_call"), "name": .string(name), "call_id": .string(id),
      "arguments": .string(#"{"cmd":"printf hello","workdir":"/tmp/project"}"#),
    ])])
  }
  private func result(_ output: String, id: String = "setup") -> JSONValue {
    .object(["type": .string("raw_response_item"), "item": .object([
      "type": .string("function_call_output"), "call_id": .string(id), "output": .string(output),
    ])])
  }

  func testMissingLifecycleStillShowsFailedCommandAndNeverDuplicatesRow() {
    var executions: [MCPToolExecution] = [], items: [ChatResponseItem] = []
    XCTAssertTrue(CodexCommandTimeline.applyResponseItem(call(), executions: &executions, items: &items))
    XCTAssertEqual(executions[0].arguments, "/tmp/project\n$ printf hello")
    let output = "Chunk ID: fixture\nProcess exited with code 65\nOutput:\nsandbox-exec: unbound variable\n"
    XCTAssertTrue(CodexCommandTimeline.applyResponseItem(result(output), executions: &executions, items: &items))
    XCTAssertEqual(executions[0].status, .failed)
    XCTAssertEqual(executions[0].output, "sandbox-exec: unbound variable\n")
    XCTAssertFalse(CodexCommandTimeline.applyResponseItem(call(), executions: &executions, items: &items))
    XCTAssertFalse(CodexCommandTimeline.applyResponseItem(result(output), executions: &executions, items: &items))
    XCTAssertEqual(items, [.tool(executions[0].id)])
  }

  func testSetupErrorsWithoutFormattedOutputAreRecordedAndOtherToolsAreIgnored() {
    for output in ["Error parsing function call: invalid arguments", "failed to create unified exec process: missing cwd"] {
      var executions: [MCPToolExecution] = [], items: [ChatResponseItem] = []
      XCTAssertFalse(CodexCommandTimeline.applyResponseItem(call(name: "other_tool"), executions: &executions, items: &items))
      XCTAssertTrue(CodexCommandTimeline.applyResponseItem(call(), executions: &executions, items: &items))
      XCTAssertFalse(CodexCommandTimeline.applyResponseItem(result(output, id: "other"), executions: &executions, items: &items))
      XCTAssertTrue(CodexCommandTimeline.applyResponseItem(result(output), executions: &executions, items: &items))
      XCTAssertEqual(executions[0].status, .failed)
      XCTAssertEqual(executions[0].output, output)
      XCTAssertEqual(items.count, 1)
    }
  }

  func testOnlyTrustedHeaderSetsExitStatusAndLateResultsKeepDeniedStatus() {
    var executions: [MCPToolExecution] = [], items: [ChatResponseItem] = []
    _ = CodexCommandTimeline.applyResponseItem(call(), executions: &executions, items: &items)
    _ = CodexCommandTimeline.applyResponseItem(result("Chunk ID: fixture\nProcess exited with code 0\nOutput:\nProcess exited with code 1\nError: example text"), executions: &executions, items: &items)
    XCTAssertEqual(executions[0].status, .succeeded)
    XCTAssertTrue(executions[0].output?.contains("Error: example text") == true)
    _ = CodexCommandTimeline.applyResponseItem(call(id: "denied"), executions: &executions, items: &items)
    CodexCommandTimeline.resolve(callID: "denied", patch: false, allowed: false, executions: &executions)
    _ = CodexCommandTimeline.applyResponseItem(result("Chunk ID: late\nProcess exited with code 0\nOutput:\nlate result", id: "denied"), executions: &executions, items: &items)
    XCTAssertEqual(executions[1].status, .denied)
    XCTAssertEqual(items.count, 2)
  }

  func testNormalLifecycleSharesTheRawCallRowAndInteractiveResultStaysRunning() {
    var executions: [MCPToolExecution] = [], items: [ChatResponseItem] = []
    _ = CodexCommandTimeline.applyResponseItem(call(), executions: &executions, items: &items)
    let begin: JSONValue = .object(["type": .string("exec_command_begin"), "call_id": .string("setup"),
      "command": .array([.string("printf"), .string("hello")]), "cwd": .string("/tmp/project")])
    XCTAssertTrue(CodexCommandTimeline.apply(begin, executions: &executions, items: &items))
    _ = CodexCommandTimeline.applyResponseItem(result("Chunk ID: fixture\nProcess running with session ID 2\nOutput:\nhello"), executions: &executions, items: &items)
    XCTAssertEqual(executions[0].status, .running)
    let end: JSONValue = .object(["type": .string("exec_command_end"), "call_id": .string("setup"),
      "status": .string("completed"), "exit_code": .number(0), "aggregated_output": .string("hello")])
    XCTAssertTrue(CodexCommandTimeline.apply(end, executions: &executions, items: &items))
    XCTAssertEqual(executions[0].status, .succeeded)
    XCTAssertEqual(executions.count, 1)
    XCTAssertEqual(items, [.tool(executions[0].id)])
  }
}
