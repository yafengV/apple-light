import XCTest
@testable import ShipiOS

final class TaskSummarySourceTests: XCTestCase {
  func testSourcesUseOnlyTaskRunAttachmentsAndObservedTools() throws {
    let file = FileAttachment(id: UUID(), name: "notes.md", byteCount: 4,
      sha256: "hash", isPDF: false)
    let image = ImageAttachment(id: UUID(), name: "screen.png", mimeType: "image/png",
      byteCount: 4, sha256: "hash")
    let serverID = UUID()
    let executions = [
      MCPToolExecution(callID: "tool-1", serverID: serverID, serverName: "Files",
        toolName: "read", arguments: "{}", status: .succeeded),
      MCPToolExecution(callID: "tool-2", serverID: serverID, serverName: "Files",
        toolName: "search", arguments: "{}", status: .succeeded),
      MCPToolExecution(callID: "shell", serverID: CodexCommandTimeline.serverID,
        serverName: "Codex", toolName: "命令", arguments: "{}", status: .succeeded),
      MCPToolExecution(callID: "web", serverID: CodexWebSearchTimeline.serverID,
        serverName: "Codex", toolName: "网页", arguments: "{}", status: .succeeded),
    ]
    let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(executions))
    let external = CodexWebSource(title: "Reference docs", url: "https://example.test/docs")
    let webSources = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode([external]))
    let first = AgentRun(id: "first", kind: "chat", project: "", status: "succeeded",
      createdAt: 0, updatedAt: 0, request: .null,
      result: .object(["tool_executions": value, "codex_web_sources": webSources]))
    let second = AgentRun(id: "second", kind: "chat", project: "", status: "succeeded",
      createdAt: 1, updatedAt: 1, request: .null, result: nil)
    let foreign = AgentRun(id: "foreign", kind: "chat", project: "", status: "succeeded",
      createdAt: 2, updatedAt: 2, request: .null, result: nil)
    var library = WorkspaceLibrary()
    library.runFiles = ["first": [file], "second": [file], "foreign": [
      FileAttachment(id: UUID(), name: "foreign.txt", byteCount: 1,
        sha256: "other", isPDF: false),
    ]]
    library.runImages = ["first": [image], "second": [image]]

    XCTAssertEqual([first, second].summarySources(in: library), [
      .file(file), .image(image), .external(external),
      .tool(id: serverID, name: "Files"),
      .webSearch(CodexWebSearchSummary(queryCount: 0, queries: [], viewedLinks: [])),
    ])
    XCTAssertTrue([foreign].summarySources(in: WorkspaceLibrary()).isEmpty)
  }

  func testSourcesKeepSuccessfulSiteToolCallsByWebsiteWithoutRequestArguments() throws {
    var completed = MCPToolExecution(callID: "site-1", serverID: CodexBrowserTimeline.serverID,
      serverName: "浏览器", toolName: "调用站点工具", arguments: "read_title · https://example.test/docs",
      status: .succeeded)
    completed.browserSiteTool = BrowserSiteToolActivity(name: "read_title", title: "Docs",
      url: "https://example.test/docs")
    completed.siteToolInputJSON = "{\"section\":\"intro\"}"
    completed.siteToolOutputJSON = "{\"title\":\"Docs\"}"
    var denied = MCPToolExecution(callID: "site-2", serverID: CodexBrowserTimeline.serverID,
      serverName: "浏览器", toolName: "调用站点工具", arguments: "delete_item", status: .denied)
    denied.browserSiteTool = BrowserSiteToolActivity(name: "delete_item", title: "Docs",
      url: "https://example.test/docs")
    let encoded = try JSONDecoder().decode(JSONValue.self,
      from: JSONEncoder().encode([completed, denied]))
    let run = AgentRun(id: "site-run", kind: "chat", project: "", status: "succeeded",
      createdAt: 0, updatedAt: 0, request: .null,
      result: .object(["tool_executions": encoded]))
    let sources = [run].summarySources(in: WorkspaceLibrary())
    XCTAssertEqual(sources, [.siteTool(completed)])
    XCTAssertEqual(sources.first?.searchableText, "read_title Docs https://example.test/docs")
  }

  func testWebSearchSourcesCountRepeatedQueriesAndGroupUniqueOpenedPages() throws {
    var executions: [MCPToolExecution] = []
    var items: [ChatResponseItem] = []
    func finish(_ id: String, action: JSONValue, results: JSONValue = .null) {
      XCTAssertTrue(CodexWebSearchTimeline.apply(.object([
        "type": .string("web_search_end"), "call_id": .string(id),
        "action": action, "results": results,
      ]), executions: &executions, items: &items))
    }
    finish("search", action: .object([
      "type": .string("search"),
      "queries": .array([.string("swift ui"), .string("swift ui"), .string("ShipiOS")]),
    ]))
    finish("open", action: .object([
      "type": .string("open_page"), "url": .string("https://example.test/docs"),
    ]), results: .array([.object([
      "title": .string("Reference docs"), "url": .string("https://example.test/docs"),
    ])]))
    finish("find", action: .object([
      "type": .string("find_in_page"), "url": .string("https://example.test/docs"),
      "pattern": .string("setup"),
    ]))
    finish("second", action: .object([
      "type": .string("open_page"), "url": .string("https://example.test/guide"),
    ]))
    let encoded = try JSONDecoder().decode(JSONValue.self,
      from: JSONEncoder().encode(executions))
    let run = AgentRun(id: "search-run", kind: "chat", project: "", status: "succeeded",
      createdAt: 0, updatedAt: 0, request: .null,
      result: .object(["tool_executions": encoded]))
    let source = try XCTUnwrap([run].summarySources(in: WorkspaceLibrary()).last)
    guard case .webSearch(let summary) = source else { return XCTFail("Missing web search source") }
    XCTAssertEqual(summary.queryCount, 3)
    XCTAssertEqual(summary.queries, ["swift ui", "ShipiOS"])
    XCTAssertEqual(summary.viewedLinks, [
      CodexWebSource(title: "Reference docs", url: "https://example.test/docs"),
      CodexWebSource(title: "example.test", url: "https://example.test/guide"),
    ])
    XCTAssertTrue(source.searchableText.contains("swift ui"))
    XCTAssertTrue(source.searchableText.contains("example.test/guide"))
  }
}
