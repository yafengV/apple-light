import XCTest
@testable import ShipiOS

final class CodexWebSourceTests: XCTestCase {
  func testCompletedSearchOnlyRecordsValidatedStructuredWebSources() {
    let event: JSONValue = .object([
      "type": .string("web_search_end"),
      "results": .array([
        .object(["title": .string("Reference docs"), "url": .string("https://example.test/docs")]),
        .object(["title": .string("Duplicate"), "url": .string("https://example.test/docs")]),
        .object(["title": .string("Local"), "url": .string("file:///tmp/private")]),
        .object(["title": .string("Credentials"), "url": .string("https://name:secret@example.test/")]),
      ]),
      "action": .object(["type": .string("open_page"),
        "url": .string("https://example.test/docs")]),
    ])
    XCTAssertEqual(CodexWebSource.completed(event), [
      CodexWebSource(title: "Reference docs", url: "https://example.test/docs"),
    ])
    XCTAssertEqual(CodexWebSource.completed(.object([
      "type": .string("web_search_end"),
      "action": .object(["type": .string("open_page"),
        "url": .string("https://example.test/other")]),
    ])), [CodexWebSource(title: "example.test", url: "https://example.test/other")])
    XCTAssertTrue(CodexWebSource.completed(.object(["type": .string("web_search_begin")])).isEmpty)
  }

  @MainActor func testSourcesSurviveLaterResponseUpdatesAndRestore() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    let run = AgentRun(id: "run", kind: "chat", project: "", status: "running",
      createdAt: 0, updatedAt: 0, request: .null, result: .object(["response": .string("")]))
    store.library.tasks = [WorkspaceTask(id: "task", project: "", title: "Web", runIDs: [run.id])]
    store.library.chatRuns = [run]
    let source = CodexWebSource(title: "Reference docs", url: "https://example.test/docs")
    store.replaceChat(run, status: "running", response: "", codexWebSources: [source])
    let updated = try XCTUnwrap(store.library.chatRuns.first)
    XCTAssertEqual(updated.codexWebSources, [source])
    store.replaceChat(updated, status: "succeeded", response: "Done")
    XCTAssertEqual(store.library.chatRuns.first?.codexWebSources, [source])
    XCTAssertTrue(store.saveLibrary())
    await store.shutdown()
    let restored = WorkspaceStore(dataRoot: root)
    await restored.restore()
    XCTAssertEqual(restored.library.chatRuns.first?.codexWebSources, [source])
    await restored.shutdown()
  }
}
