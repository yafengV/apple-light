import XCTest
@testable import ShipiOS

final class TaskExternalResourceCatalogTests: XCTestCase {
  private func run(_ id: String, serverID: UUID, resourceID: String,
    url: String, title: String, activities: [TaskExternalSourceActivity]) throws -> AgentRun {
    var execution = MCPToolExecution(callID: id, serverID: serverID,
      serverName: "Documents", toolName: "read", arguments: "{}", status: .succeeded)
    execution.mcpResourceActivities = [MCPResourceActivity(id: resourceID,
      source: CodexWebSource(title: title, url: url), mimeType: "text/html",
      activities: activities)]
    return AgentRun(id: id, kind: "chat", project: "", status: "succeeded",
      createdAt: 0, updatedAt: 0, request: .null,
      result: .object(["tool_executions": try JSONDecoder().decode(JSONValue.self,
        from: JSONEncoder().encode([execution]))]))
  }

  func testSameProviderResourceMovesURLWithoutSplittingSourceAndOutput() throws {
    let serverID = UUID()
    let old = try run("create", serverID: serverID, resourceID: "document-1",
      url: "https://example.test/old", title: "Draft", activities: [.created])
    let new = try run("read", serverID: serverID, resourceID: "document-1",
      url: "https://example.test/new", title: "Final", activities: [.read])
    let catalog = TaskExternalResourceCatalog.collect([old, new], library: WorkspaceLibrary())
    XCTAssertEqual(catalog.entries.count, 1)
    let resource = try XCTUnwrap(catalog.sources.first?.source)
    XCTAssertEqual(resource.id, "provider:\(serverID.uuidString):document-1")
    XCTAssertEqual(resource.url, "https://example.test/new")
    XCTAssertEqual(resource.title, "Final")
    XCTAssertEqual(resource.activities, [.read, .created])
    XCTAssertEqual(catalog.artifacts, [resource])
    let sources = [old, new].summarySources(in: WorkspaceLibrary()).compactMap { item -> TaskExternalSource? in
      if case .external(let source) = item { return source }
      return nil
    }
    XCTAssertEqual(sources, [resource])
    XCTAssertEqual([old, new].summaryExternalArtifacts(in: WorkspaceLibrary()), [resource])
  }

  func testURLBridgesDifferentResourceIDsIntoOneEntry() throws {
    let serverID = UUID()
    let first = try run("first", serverID: serverID, resourceID: "original",
      url: "https://example.test/old", title: "Document", activities: [.created])
    let second = try run("second", serverID: serverID, resourceID: "copy",
      url: "https://example.test/new", title: "Copy", activities: [.read])
    let bridge = try run("bridge", serverID: serverID, resourceID: "original",
      url: "https://example.test/new", title: "Document", activities: [.updated])
    let catalog = TaskExternalResourceCatalog.collect([first, second, bridge],
      library: WorkspaceLibrary())
    XCTAssertEqual(catalog.entries.count, 1)
    XCTAssertEqual(catalog.sources.first?.source.url, "https://example.test/new")
    XCTAssertEqual(catalog.sources.first?.source.activities, [.read, .created, .updated])
    XCTAssertEqual(catalog.artifacts.count, 1)
  }

  func testCanonicalDocumentIdentityMergesProvidedAndReadURLVariants() throws {
    let read = CodexWebSource(title: "Google Docs",
      url: "https://docs.google.com/document/d/doc-123/view")
    let run = AgentRun(id: "google-doc", kind: "chat", project: "", status: "succeeded",
      createdAt: 0, updatedAt: 0, request: .null,
      result: .object(["codex_web_sources": try JSONDecoder().decode(JSONValue.self,
        from: JSONEncoder().encode([read]))]))
    var library = WorkspaceLibrary()
    library.notes[run.id] = "查看 [Project plan](https://docs.google.com/document/d/doc-123/edit)"
    let catalog = TaskExternalResourceCatalog.collect([run], library: library)
    XCTAssertEqual(catalog.entries.count, 1)
    XCTAssertEqual(catalog.sources.first?.source.id, "google:document:doc-123")
    XCTAssertEqual(catalog.sources.first?.source.title, "Project plan")
    XCTAssertEqual(catalog.sources.first?.source.url, read.url)
    XCTAssertEqual(catalog.sources.first?.source.activities, [.provided, .read])
  }
}
