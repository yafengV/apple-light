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
    let first = AgentRun(id: "first", kind: "chat", project: "", status: "succeeded",
      createdAt: 0, updatedAt: 0, request: .null,
      result: .object(["tool_executions": value]))
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
      .file(file), .image(image), .tool(id: serverID, name: "Files"), .webSearch,
    ])
    XCTAssertTrue([foreign].summarySources(in: WorkspaceLibrary()).isEmpty)
  }
}
