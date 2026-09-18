import XCTest
@testable import ShipiOS

final class ChatResponseItemTests: XCTestCase {
  private func execution() -> MCPToolExecution {
    MCPToolExecution(callID: "call", serverID: UUID(), serverName: "server", toolName: "tool", arguments: "{}")
  }
  private func run(_ text: String, executions: [MCPToolExecution], items: [ChatResponseItem]?) throws -> AgentRun {
    var result: [String: JSONValue] = ["response": .string(text),
      "tool_executions": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(executions))]
    if let items { result["response_items"] = try ChatResponseItem.json(items) }
    return AgentRun(id: "run", kind: "chat", project: "", status: "succeeded", createdAt: 0,
      updatedAt: 0, request: .object([:]), result: .object(result))
  }

  func testStreamingPreservesMessageIdentityAndSeparatesToolBoundaries() throws {
    var items: [ChatResponseItem] = []
    ChatResponseItem.append("👩🏽‍", to: &items)
    let first = items[0].id
    ChatResponseItem.append("💻 e", to: &items)
    ChatResponseItem.append("\u{301}", to: &items)
    XCTAssertEqual(items[0].id, first)
    XCTAssertEqual(items[0].text, "👩🏽‍💻 e\u{301}")
    let tool = execution()
    items.append(.tool(tool.id))
    ChatResponseItem.append("", to: &items)
    XCTAssertEqual(items.count, 2)
    ChatResponseItem.append("after", to: &items)
    XCTAssertEqual(items.count, 3)
    XCTAssertEqual(Set(items.map(\.id)).count, 3)
    let value = try run("👩🏽‍💻 e\u{301}after", executions: [tool], items: items)
    XCTAssertEqual(value.responseItems, items)
    XCTAssertEqual(try ChatResponseItem.json(items).decode([ChatResponseItem].self), items)
  }

  func testLegacyAndInvalidRecordsKeepAllTextAndToolsWithoutInventingChronology() throws {
    let tool = execution()
    for items: [ChatResponseItem]? in [nil, [.tool(UUID())], [.tool(tool.id), .tool(tool.id)], []] {
      let value = try run("preserved response", executions: [tool], items: items)
      XCTAssertNil(value.responseItems)
      XCTAssertEqual(value.displayedResponseItems.first, .tool(tool.id))
      XCTAssertEqual(value.displayedResponseItems.last?.text, "preserved response")
    }
  }

  func testSearchUsesTheSameSegmentIDsAsRenderedMarkdownInChronologicalOrder() throws {
    let tool = execution()
    let before = ChatResponseItem.message(id: UUID(), text: "# needle\n\n> quoted needle")
    let after = ChatResponseItem.message(id: UUID(), text: "```swift\nneedle\n```\n\n| A | B |\n| --- | --- |\n| needle | value |")
    let value = try run("unused aggregate needle", executions: [tool], items: [before, .tool(tool.id), after])
    let inputs = ConversationSearch.inputs([value], library: WorkspaceLibrary())
    let matches = ConversationSearch.find(inputs, query: "needle")
    XCTAssertEqual(matches.count, 4, "Do not duplicate matches from the aggregate response")
    XCTAssertEqual(Set(matches.map(\.textID)).count, 4)
    XCTAssertTrue(matches.prefix(2).allSatisfy { $0.textID.part.hasPrefix(before.searchPrefix + ".") })
    XCTAssertTrue(matches.suffix(2).allSatisfy { $0.textID.part.hasPrefix(after.searchPrefix + ".") })
  }
}
