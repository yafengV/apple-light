import XCTest
@testable import ShipiOS

final class CodexBrowserTimelineTests: XCTestCase {
  func testRequestAndResultUpdateOneToolCardAndAddOnlyApprovedSource() {
    let id = UUID().uuidString
    var executions: [MCPToolExecution] = []
    var items: [ChatResponseItem] = []
    let request: JSONValue = .object([
      "type": .string("browser_request"), "requestId": .string(id),
      "action": .string("read"), "tabId": .string(UUID().uuidString),
    ])
    XCTAssertTrue(CodexBrowserTimeline.apply(request, executions: &executions, items: &items))
    XCTAssertEqual(executions.count, 1)
    XCTAssertEqual(items.count, 1)
    XCTAssertEqual(executions[0].status, .running)

    let denied: JSONValue = .object([
      "type": .string("browser_result"), "requestId": .string(id),
      "result": .object(["status": .string("denied"), "url": .string("https://example.com/private")]),
    ])
    XCTAssertTrue(CodexBrowserTimeline.apply(denied, executions: &executions, items: &items))
    XCTAssertEqual(executions.count, 1)
    XCTAssertEqual(items.count, 1)
    XCTAssertEqual(executions[0].status, .denied)
    XCTAssertNil(CodexBrowserTimeline.source(denied))

    let approved: JSONValue = .object([
      "type": .string("browser_result"), "requestId": .string(id),
      "result": .object(["status": .string("ok"), "url": .string("https://example.com/guide"),
        "title": .string("Guide"), "text": .string("Visible text")]),
    ])
    XCTAssertTrue(CodexBrowserTimeline.apply(approved, executions: &executions, items: &items))
    XCTAssertEqual(executions[0].status, .succeeded)
    XCTAssertEqual(CodexBrowserTimeline.source(approved)?.title, "Guide")
    XCTAssertEqual(CodexBrowserTimeline.source(approved)?.url, "https://example.com/guide")
  }
}
