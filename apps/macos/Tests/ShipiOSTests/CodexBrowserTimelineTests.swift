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

  func testFillCardShowsElementLabelWithoutPersistingTypedTextInArguments() {
    let id = UUID().uuidString
    var executions: [MCPToolExecution] = []
    var items: [ChatResponseItem] = []
    let request: JSONValue = .object([
      "type": .string("browser_request"), "requestId": .string(id),
      "action": .string("fill"), "tabId": .string(UUID().uuidString),
      "handle": .string("scan:1"), "text": .string("private draft"),
    ])
    XCTAssertTrue(CodexBrowserTimeline.apply(request, executions: &executions, items: &items))
    XCTAssertFalse(executions[0].arguments.contains("private draft"))
    let result: JSONValue = .object([
      "type": .string("browser_result"), "requestId": .string(id),
      "result": .object(["status": .string("ok"), "action": .string("fill"),
        "label": .string("Title"), "url": .string("https://example.com/editor")]),
    ])
    XCTAssertTrue(CodexBrowserTimeline.apply(result, executions: &executions, items: &items))
    XCTAssertEqual(executions[0].arguments, "Title · https://example.com/editor")
    XCTAssertEqual(executions[0].toolName, "填写网页控件")
  }

  func testInterruptedBrowserCallDoesNotStayRunning() {
    var executions: [MCPToolExecution] = []
    var items: [ChatResponseItem] = []
    let request: JSONValue = .object([
      "type": .string("browser_request"), "requestId": .string(UUID().uuidString),
      "action": .string("click"), "tabId": .string(UUID().uuidString),
    ])
    XCTAssertTrue(CodexBrowserTimeline.apply(request, executions: &executions, items: &items))
    XCTAssertTrue(CodexBrowserTimeline.expirePending(&executions, status: .cancelled))
    XCTAssertEqual(executions[0].status, .cancelled)
    XCTAssertFalse(CodexBrowserTimeline.expirePending(&executions, status: .failed))
  }

  func testSiteToolCallHasNamedCardAndCurrentPageSourceWithoutPersistingArguments() {
    let id = UUID().uuidString
    var executions: [MCPToolExecution] = []
    var items: [ChatResponseItem] = []
    let request: JSONValue = .object([
      "type": .string("browser_request"), "requestId": .string(id),
      "action": .string("site_tool_call"), "siteTool": .string("read_title"),
      "tabId": .string(UUID().uuidString),
      "arguments": .object(["secret": .string("private draft")]),
    ])
    XCTAssertTrue(CodexBrowserTimeline.apply(request, executions: &executions, items: &items))
    XCTAssertEqual(executions.first?.toolName, "调用站点工具")
    XCTAssertEqual(executions.first?.arguments, "read_title")
    XCTAssertFalse(executions.first?.arguments.contains("private draft") ?? true)
    XCTAssertTrue(executions.first?.siteToolInputJSON?.contains("private draft") == true,
      "Sources keeps the approved call input without putting it in the timeline title")
    let result: JSONValue = .object([
      "type": .string("browser_result"), "requestId": .string(id),
      "result": .object(["status": .string("ok"), "url": .string("https://example.com/docs"),
        "origin_url": .string("https://example.com/original"),
        "title": .string("New page"), "origin_title": .string("Docs"),
        "site_tool": .string("read_title"),
        "output": .string("{\"result\":\"done\"}"), "truncated": .bool(true)]),
    ])
    XCTAssertTrue(CodexBrowserTimeline.apply(result, executions: &executions, items: &items))
    XCTAssertEqual(executions.first?.arguments, "read_title · https://example.com/docs")
    XCTAssertEqual(executions.first?.browserSiteTool,
      BrowserSiteToolActivity(name: "read_title", title: "Docs", url: "https://example.com/original"))
    XCTAssertEqual(executions.first?.siteToolOutputJSON, "{\"result\":\"done\"}")
    XCTAssertEqual(executions.first?.siteToolOutputTruncated, true)
    XCTAssertEqual(CodexBrowserTimeline.source(result)?.url, "https://example.com/docs")
    let catalog: JSONValue = .object([
      "type": .string("browser_result"), "requestId": .string(UUID().uuidString),
      "result": .object(["status": .string("ok"), "url": .string("https://example.com/docs"),
        "tools": .array([.object(["name": .string("read_title")])])]),
    ])
    XCTAssertNil(CodexBrowserTimeline.source(catalog),
      "Listing available tools is not a recently used site-tool source")
  }

  func testDeniedSiteToolCallDoesNotRetainInputInSourcesMetadata() {
    let id = UUID().uuidString
    var executions: [MCPToolExecution] = []
    var items: [ChatResponseItem] = []
    XCTAssertTrue(CodexBrowserTimeline.apply(.object([
      "type": .string("browser_request"), "requestId": .string(id),
      "action": .string("site_tool_call"), "siteTool": .string("send_message"),
      "arguments": .object(["message": .string("private draft")]),
    ]), executions: &executions, items: &items))
    XCTAssertTrue(CodexBrowserTimeline.apply(.object([
      "type": .string("browser_result"), "requestId": .string(id),
      "result": .object(["status": .string("denied")]),
    ]), executions: &executions, items: &items))
    XCTAssertNil(executions.first?.browserSiteTool)
    XCTAssertNil(executions.first?.siteToolInputJSON)
    XCTAssertNil(executions.first?.siteToolOutputJSON)
  }

  func testInterruptedSiteToolCallDoesNotRetainInputInSourcesMetadata() {
    var executions: [MCPToolExecution] = []
    var items: [ChatResponseItem] = []
    XCTAssertTrue(CodexBrowserTimeline.apply(.object([
      "type": .string("browser_request"), "requestId": .string(UUID().uuidString),
      "action": .string("site_tool_call"), "siteTool": .string("send_message"),
      "arguments": .object(["message": .string("private draft")]),
    ]), executions: &executions, items: &items))
    XCTAssertTrue(CodexBrowserTimeline.expirePending(&executions, status: .cancelled))
    XCTAssertNil(executions.first?.siteToolInputJSON)
    XCTAssertNil(executions.first?.siteToolInputTruncated)
  }
}
