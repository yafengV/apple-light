import XCTest

@testable import ShipiOS

final class CodexElicitationSchemaTests: XCTestCase {
  func testFormattedFieldsRejectInvalidValuesBeforeSubmitting() {
    let request = CodexElicitationRequest(serverName: "fixture", requestID: .string("request"),
      message: "Contact details", schema: .object([
        "type": .string("object"),
        "properties": .object([
          "website": .object(["type": .string("string"), "format": .string("uri")]),
          "day": .object(["type": .string("string"), "format": .string("date")]),
          "when": .object(["type": .string("string"), "format": .string("date-time")]),
        ]),
        "required": .array([.string("website"), .string("day"), .string("when")]),
      ]))
    func values(_ website: String, _ day: String, _ when: String) -> JSONValue {
      .object(["website": .string(website), "day": .string(day), "when": .string(when)])
    }
    XCTAssertTrue(request.validContent(values("https://example.com", "2026-09-26",
      "2026-09-26T12:30:00Z")))
    XCTAssertFalse(request.validContent(values("example.com", "2026-09-26",
      "2026-09-26T12:30:00Z")))
    XCTAssertFalse(request.validContent(values("https://example.com", "2026-13-26",
      "2026-09-26T12:30:00Z")))
    XCTAssertFalse(request.validContent(values("https://example.com", "2026-09-26",
      "tomorrow")))
  }
}
