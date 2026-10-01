import XCTest
@testable import ShipiOS

final class MCPResourceFallbackTests: XCTestCase {
  private func textResult(_ value: JSONValue) -> JSONValue {
    .object(["content": .array([.object([
      "type": .string("text"), "text": .string(value.pretty),
    ])])])
  }

  func testFigmaCreateFileUsesStructuredTextOnlyForKnownTool() throws {
    let result = textResult(.object([
      "file_key": .string("figma-123"), "file_url": .string("https://figma.com/design/figma-123"),
      "message": .string("File \"Mockup\" created successfully."),
    ]))
    let resource = MCPResourceActivity.extract(result, serverName: "Figma",
      toolName: "figma_create_new_file").first
    XCTAssertEqual(resource?.source.title, "Mockup")
    XCTAssertEqual(resource?.activities, [.created])
    XCTAssertEqual(resource?.id, "figma-123")
    XCTAssertEqual(resource?.usesProviderID, true)
    let saved = try XCTUnwrap(resource)
    XCTAssertEqual(try JSONDecoder().decode(MCPResourceActivity.self,
      from: JSONEncoder().encode(saved)), saved)
    XCTAssertTrue(MCPResourceActivity.extract(result, serverName: "Other",
      toolName: "print_text").isEmpty)
  }

  func testNotionFetchAndCreatePagesHaveDifferentActivities() {
    let fetched = textResult(.object([
      "metadata": .object(["type": .string("page")]),
      "title": .string("Notes"), "url": .string("https://notion.so/notes"),
    ]))
    let read = MCPResourceActivity.extract(fetched, serverName: "Notion", toolName: "notion-fetch")
    XCTAssertEqual(read.first?.activities, [.read])
    XCTAssertEqual(read.first?.usesProviderID, false)
    let created = textResult(.object(["pages": .array([
      .object(["id": .string("page-1"), "url": .string("https://notion.so/page-1"),
        "properties": .object(["title": .string("First")])]),
      .object(["id": .string("page-2"), "url": .string("https://notion.so/page-2"),
        "properties": .object(["title": .string("Second")])]),
    ])]))
    let pages = MCPResourceActivity.extract(created, serverName: "Notion",
      toolName: "notion-create-pages")
    XCTAssertEqual(pages.map(\.id), ["page-1", "page-2"])
    XCTAssertEqual(pages.map(\.activities), [[.created], [.created]])
    XCTAssertTrue(pages.allSatisfy { $0.usesProviderID == true })
  }

  func testGoogleDriveClassifiesOnlyKnownToolsAndStructuredURL() {
    let result: JSONValue = .object(["structuredContent": .object([
      "webViewLink": .string("https://drive.google.com/file/d/report/view"),
      "name": .string("Report"), "mimeType": .string("application/pdf"),
    ])])
    let read = MCPResourceActivity.extract(result, serverName: "Google Drive",
      toolName: "get_file_metadata")
    XCTAssertEqual(read.first?.activities, [.read])
    XCTAssertEqual(read.first?.source.title, "Report")
    XCTAssertEqual(read.first?.mimeType, "application/pdf")
    XCTAssertEqual(MCPResourceActivity.extract(result, serverName: "Google Drive",
      toolName: "copy_file").first?.activities, [.created])
    XCTAssertEqual(MCPResourceActivity.extract(result, serverName: "Google Drive",
      toolName: "share_file").first?.activities, [.updated])
    XCTAssertEqual(MCPResourceActivity.extract(result, serverName: "Plugin",
      toolName: "Google Drive.get_file_metadata").first?.activities, [.read])
    XCTAssertEqual(MCPResourceActivity.extract(result, serverName: "Plugin",
      toolName: "google_drive_copy_file").first?.activities, [.created])
    XCTAssertTrue(MCPResourceActivity.extract(result, serverName: "Google Drive",
      toolName: "delete_file").isEmpty)
    XCTAssertTrue(MCPResourceActivity.extract(result, serverName: "Other",
      toolName: "copy_file").isEmpty)
  }

  func testMalformedExplicitMetadataSuppressesFallback() {
    let result: JSONValue = .object([
      "_meta": .object(["openai/resourceActivities": .string("invalid")]),
      "structuredContent": .object(["url": .string("https://drive.google.com/file/d/x")]),
    ])
    XCTAssertTrue(MCPResourceActivity.extract(result, serverName: "Google Drive",
      toolName: "get_file_metadata").isEmpty)
  }

  func testOlderToolOutputCanBeRestoredToTaskSources() throws {
    let result = textResult(.object([
      "metadata": .object(["type": .string("page")]),
      "title": .string("Notes"), "url": .string("https://notion.so/notes"),
    ]))
    var execution = MCPToolExecution(callID: "notion", serverID: UUID(), serverName: "Notion",
      toolName: "notion-fetch", arguments: "{}", status: .succeeded)
    execution.output = result.pretty
    let run = AgentRun(id: "legacy", kind: "chat", project: "", status: "succeeded",
      createdAt: 0, updatedAt: 0, request: .null,
      result: .object(["tool_executions": try JSONDecoder().decode(JSONValue.self,
        from: JSONEncoder().encode([execution]))]))
    let sources = [run].summarySources(in: WorkspaceLibrary())
    XCTAssertTrue(sources.contains { source in
      guard case .external(let resource) = source else { return false }
      return resource.title == "Notes" && resource.activities == [.read]
    })
  }

  func testInferredCreatedFileAppearsOnlyInOutputs() throws {
    let result = textResult(.object([
      "file_key": .string("design-1"),
      "file_url": .string("https://figma.com/design/design-1"),
      "message": .string("File \"Design\" created successfully."),
    ]))
    var execution = MCPToolExecution(callID: "figma", serverID: UUID(), serverName: "Figma",
      toolName: "figma-create-new-file", arguments: "{}", status: .succeeded)
    execution.output = result.pretty
    let run = AgentRun(id: "create", kind: "chat", project: "", status: "succeeded",
      createdAt: 0, updatedAt: 0, request: .null,
      result: .object(["tool_executions": try JSONDecoder().decode(JSONValue.self,
        from: JSONEncoder().encode([execution]))]))
    XCTAssertFalse([run].summarySources(in: WorkspaceLibrary()).contains {
      if case .external = $0 { return true }; return false
    })
    let artifact = try XCTUnwrap([run].summaryExternalArtifacts(in: WorkspaceLibrary()).first)
    XCTAssertEqual(artifact.title, "Design")
    XCTAssertEqual(artifact.activities, [.created])
  }
}
