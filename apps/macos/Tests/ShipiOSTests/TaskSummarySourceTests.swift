import XCTest
@testable import ShipiOS

final class TaskSummarySourceTests: XCTestCase {
  func testMCPResourceQualificationAcrossTurns() throws {
    let serverID = UUID()
    let source = CodexWebSource(title: "Document", url: "https://example.test/document")
    func run(_ id: String, _ activities: [TaskExternalSourceActivity]) throws -> AgentRun {
      var execution = MCPToolExecution(callID: id, serverID: serverID, serverName: "Documents",
        toolName: "write", arguments: "{}", status: .succeeded)
      execution.output = "truncated output"
      execution.mcpResourceActivities = [MCPResourceActivity(id: "document-1", source: source,
        mimeType: "text/html", activities: activities)]
      return AgentRun(id: id, kind: "chat", project: "", status: "succeeded",
        createdAt: 0, updatedAt: 0, request: .null,
        result: .object(["tool_executions": try JSONDecoder().decode(JSONValue.self,
          from: JSONEncoder().encode([execution]))]))
    }
    let created = try run("created", [.created])
    let readAndCreated = try run("read-and-created", [.read, .created])
    let read = try run("read", [.read])
    XCTAssertFalse([created].summarySources(in: WorkspaceLibrary()).contains {
      if case .external = $0 { return true }; return false
    })
    XCTAssertFalse([readAndCreated].summarySources(in: WorkspaceLibrary()).contains {
      if case .external = $0 { return true }; return false
    })
    let sources = [created, read].summarySources(in: WorkspaceLibrary())
    XCTAssertEqual(sources.first, .external(TaskExternalSource(resource: source,
      activities: [.read, .created], stableKey: "provider:\(serverID.uuidString):document-1",
      providerName: "Documents", mimeType: "text/html")))
  }

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
      .file(file), .image(image),
      .external(TaskExternalSource(resource: external, activities: [.read])),
      .tool(MCPToolSource(id: serverID, name: "Files", calls: Array(executions.prefix(2)))),
    ])
    guard case .tool(let source) = [first, second].summarySources(in: library)[3] else {
      return XCTFail("Missing grouped tool source")
    }
    XCTAssertEqual(source.activities.map(\.name), ["read", "search"])
    XCTAssertTrue([foreign].summarySources(in: WorkspaceLibrary()).isEmpty)
  }

  func testToolSourcesGroupRepeatedCallsByServerAndToolAcrossRuns() throws {
    let serverID = UUID()
    let calls = [
      MCPToolExecution(callID: "first", serverID: serverID, serverName: "Files",
        toolName: "read", arguments: "{\"path\":\"a\"}", status: .succeeded),
      MCPToolExecution(callID: "second", serverID: serverID, serverName: "Files",
        toolName: "read", arguments: "{\"path\":\"b\"}", status: .failed),
      MCPToolExecution(callID: "third", serverID: serverID, serverName: "Files",
        toolName: "write", arguments: "{\"path\":\"c\"}", status: .succeeded),
    ]
    func run(_ id: String, _ executions: [MCPToolExecution]) throws -> AgentRun {
      AgentRun(id: id, kind: "chat", project: "", status: "succeeded",
        createdAt: 0, updatedAt: 0, request: .null,
        result: .object(["tool_executions": try JSONDecoder().decode(JSONValue.self,
          from: JSONEncoder().encode(executions))]))
    }
    let sources = try [run("first", [calls[0]]), run("second", Array(calls.dropFirst()))]
      .summarySources(in: WorkspaceLibrary())
    XCTAssertEqual(sources, [.tool(MCPToolSource(id: serverID, name: "Files", calls: calls))])
    guard case .tool(let source) = sources[0] else { return XCTFail("Missing tool source") }
    XCTAssertEqual(source.activities.map(\.name), ["read", "write"])
    XCTAssertEqual(source.activities.map { $0.calls.count }, [2, 1])
    XCTAssertEqual(source.activities[0].calls.map(\.status), [.succeeded, .failed])
    XCTAssertTrue(sources[0].searchableText.contains("write"))
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

  func testOpenedWebSearchPageIsNotDuplicatedAsExternalSource() throws {
    let opened = CodexWebSource(title: "Reference docs", url: "https://example.test/docs")
    let browserVersion = CodexWebSource(title: "Reference docs",
      url: "https://example.test/docs/#section")
    let other = CodexWebSource(title: "Browser article", url: "https://elsewhere.test/article")
    var executions: [MCPToolExecution] = []
    var items: [ChatResponseItem] = []
    XCTAssertTrue(CodexWebSearchTimeline.apply(.object([
      "type": .string("web_search_end"), "call_id": .string("opened"),
      "action": .object(["type": .string("open_page"), "url": .string(opened.url)]),
      "results": .array([.object(["title": .string(opened.title), "url": .string(opened.url)])]),
    ]), executions: &executions, items: &items))
    let run = AgentRun(id: "run", kind: "chat", project: "", status: "succeeded",
      createdAt: 0, updatedAt: 0, request: .null,
      result: .object([
        "tool_executions": try JSONDecoder().decode(JSONValue.self,
          from: JSONEncoder().encode(executions)),
        "codex_web_sources": try JSONDecoder().decode(JSONValue.self,
          from: JSONEncoder().encode([browserVersion, other])),
      ]))
    let sources = [run].summarySources(in: WorkspaceLibrary())
    XCTAssertEqual(sources.first, .external(TaskExternalSource(resource: other, activities: [.read])))
    XCTAssertFalse(sources.contains(.external(TaskExternalSource(resource: browserVersion,
      activities: [.read]))))
    guard let last = sources.last, case .webSearch(let summary) = last else {
      return XCTFail("Missing web search source")
    }
    XCTAssertEqual(summary.viewedLinks, [opened])
  }

  func testProvidedLinksMergeWithReadActivityAndSurviveWebSearchDeduplication() throws {
    let read = CodexWebSource(title: "Docs", url: "https://example.test/docs#read")
    var executions: [MCPToolExecution] = []
    var items: [ChatResponseItem] = []
    XCTAssertTrue(CodexWebSearchTimeline.apply(.object([
      "type": .string("web_search_end"), "call_id": .string("opened"),
      "action": .object(["type": .string("open_page"),
        "url": .string("https://example.test/docs")]),
    ]), executions: &executions, items: &items))
    let run = AgentRun(id: "provided", kind: "chat", project: "", status: "succeeded",
      createdAt: 0, updatedAt: 0, request: .null,
      result: .object([
        "tool_executions": try JSONDecoder().decode(JSONValue.self,
          from: JSONEncoder().encode(executions)),
        "codex_web_sources": try JSONDecoder().decode(JSONValue.self,
          from: JSONEncoder().encode([read])),
      ]))
    var library = WorkspaceLibrary()
    library.notes[run.id] = "请查看 [项目文档](https://example.test/docs)。"
    let sources = [run].summarySources(in: library)
    guard let first = sources.first, case .external(let source) = first else {
      return XCTFail("Missing user-provided web source")
    }
    XCTAssertEqual(source.title, "项目文档")
    XCTAssertEqual(source.activities, [.provided, .read])
    XCTAssertEqual(source.id, CodexWebSource.sourceKey(read.url))
    XCTAssertFalse(sources.contains { if case .webSearch = $0 { return true }; return false })
  }

  func testMCPReadResourceReplacesDuplicateOpenedWebSearchLink() throws {
    let url = "https://example.test/report"
    var tool = MCPToolExecution(callID: "mcp", serverID: UUID(), serverName: "Reports",
      toolName: "read", arguments: "{}", status: .succeeded)
    tool.mcpResourceActivities = [MCPResourceActivity(id: "report", source: .init(
      title: "Report", url: url), mimeType: nil, activities: [.read])]
    var executions = [tool]
    var items: [ChatResponseItem] = []
    XCTAssertTrue(CodexWebSearchTimeline.apply(.object([
      "type": .string("web_search_end"), "call_id": .string("search"),
      "action": .object(["type": .string("search"), "queries": .array([.string("report")])]),
    ]), executions: &executions, items: &items))
    XCTAssertTrue(CodexWebSearchTimeline.apply(.object([
      "type": .string("web_search_end"), "call_id": .string("open"),
      "action": .object(["type": .string("open_page"), "url": .string(url)]),
    ]), executions: &executions, items: &items))
    let run = AgentRun(id: "mcp-web", kind: "chat", project: "", status: "succeeded",
      createdAt: 0, updatedAt: 0, request: .null,
      result: .object(["tool_executions": try JSONDecoder().decode(JSONValue.self,
        from: JSONEncoder().encode(executions))]))
    let sources = [run].summarySources(in: WorkspaceLibrary())
    XCTAssertEqual(sources.first, .external(TaskExternalSource(resource: .init(
      title: "Report", url: url), activities: [.read],
      stableKey: "provider:\(tool.serverID.uuidString):report", providerName: "Reports")))
    guard let last = sources.last, case .webSearch(let search) = last else {
      return XCTFail("Search query should remain")
    }
    XCTAssertEqual(search.queries, ["report"])
    XCTAssertTrue(search.viewedLinks.isEmpty)
  }

  func testKnownProviderOpenedPageRemainsAsIndependentSource() throws {
    let source = CodexWebSource(title: "Project plan",
      url: "https://docs.google.com/document/d/plan-1/view")
    var executions: [MCPToolExecution] = []
    var items: [ChatResponseItem] = []
    XCTAssertTrue(CodexWebSearchTimeline.apply(.object([
      "type": .string("web_search_end"), "call_id": .string("open-doc"),
      "action": .object(["type": .string("open_page"), "url": .string(source.url)]),
    ]), executions: &executions, items: &items))
    let run = AgentRun(id: "provider-page", kind: "chat", project: "", status: "succeeded",
      createdAt: 0, updatedAt: 0, request: .null,
      result: .object([
        "tool_executions": try JSONDecoder().decode(JSONValue.self,
          from: JSONEncoder().encode(executions)),
        "codex_web_sources": try JSONDecoder().decode(JSONValue.self,
          from: JSONEncoder().encode([source])),
      ]))
    let sources = [run].summarySources(in: WorkspaceLibrary())
    XCTAssertEqual(sources, [.external(TaskExternalSource(resource: source,
      activities: [.read], stableKey: "google:document:plan-1",
      providerName: "Google Drive", providerID: "google-drive"))])
  }

  func testSteeredUserMessageLinkAppearsAsProvidedSource() throws {
    let message = QueuedMessage(taskID: "task", text: "补充 <https://example.test/guide>")
    let run = AgentRun(id: "steered", kind: "chat", project: "", status: "succeeded",
      createdAt: 0, updatedAt: 0, request: .null,
      result: .object(["codex_steered_messages": try JSONDecoder().decode(JSONValue.self,
        from: JSONEncoder().encode([message]))]))
    XCTAssertEqual([run].summarySources(in: WorkspaceLibrary()), [
      .external(TaskExternalSource(
        resource: CodexWebSource(title: "example.test", url: "https://example.test/guide"),
        activities: [.provided])),
    ])
  }

  func testSteeredMessageAttachmentsAppearInSourcesWithoutDuplicates() throws {
    let file = FileAttachment(id: UUID(), name: "brief.pdf", byteCount: 128,
      sha256: "file", isPDF: true)
    let image = ImageAttachment(id: UUID(), name: "screen.png", mimeType: "image/png",
      byteCount: 64, sha256: "image")
    let message = QueuedMessage(taskID: "task", text: "请查看附件", images: [image], files: [file])
    let run = AgentRun(id: "steered-attachments", kind: "chat", project: "", status: "succeeded",
      createdAt: 0, updatedAt: 0, request: .null,
      result: .object(["codex_steered_messages": try JSONDecoder().decode(JSONValue.self,
        from: JSONEncoder().encode([message]))]))
    var library = WorkspaceLibrary()
    library.runFiles[run.id] = [file]
    XCTAssertEqual([run].summarySources(in: library), [.file(file), .image(image)])
  }
}
