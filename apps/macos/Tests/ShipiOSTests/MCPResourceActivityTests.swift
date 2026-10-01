import XCTest
@testable import ShipiOS

final class MCPResourceActivityTests: XCTestCase {
  private func result(_ activities: [String], version: Int = 1) -> JSONValue {
    .object(["_meta": .object(["openai/resourceActivities": .object([
      "version": .number(Double(version)),
      "resources": .array([.object([
        "id": .string("document-1"),
        "url": .string("https://example.test/document"),
        "title": .string("Document"),
        "mimeType": .string("text/html"),
        "activities": .array(activities.map(JSONValue.string)),
      ])]),
    ])])])
  }

  func testParsesExplicitResourceActivitiesAndRestoresFromOutput() {
    let value = result(["updated", "read", "created", "read"])
    let resource = MCPResourceActivity.parse(value)?.first
    XCTAssertEqual(resource?.id, "document-1")
    XCTAssertEqual(resource?.source.title, "Document")
    XCTAssertEqual(resource?.mimeType, "text/html")
    XCTAssertEqual(resource?.activities, [.read, .created, .updated])
    XCTAssertEqual(MCPResourceActivity.restored(from: value.pretty), [resource].compactMap { $0 })
  }

  func testRejectsInvalidMetadataAndFailedCalls() {
    XCTAssertNil(MCPResourceActivity.parse(result(["read"], version: 2)))
    XCTAssertNil(MCPResourceActivity.parse(result(["provided"])))
    XCTAssertNil(MCPResourceActivity.parse(result(["other"])))
    XCTAssertNil(MCPResourceActivity.parse(.object([
      "isError": .bool(true),
      "_meta": result(["read"])["_meta"],
    ])))
  }
}
