import XCTest
@testable import ShipiOS

final class ChildElicitationProjectionTests: XCTestCase {
  func testInstalledProjectionFunctionResultsForTenOrdinaryTurnCases() throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/child_elicitation_projection_reference.json")
    let data = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    XCTAssertEqual(data["moduleSHA256"].text, "33464c6a3248722495ae5b9b3d78b2fff0095ff83024fa12d49207ff3387f431")
    let cases = data["cases"].items; XCTAssertEqual(cases.count, 10)
    func entries(_ records: [JSONValue]) -> [ChildElicitationProjection.Entry] {
      records.map { record in record["type"].text == "turn" ? .turn(record["id"].text!) : .child(record["id"].text!, after: record["after"].text) }
    }
    for sample in cases {
      XCTAssertEqual(ChildElicitationProjection.project(turns: sample["turns"].items.compactMap(\.text),
        requests: sample["requests"].items.compactMap(\.text), previous: entries(sample["previous"].items)),
        entries(sample["expected"].items), sample["name"].text ?? "")
    }
  }
  func testTwoWindowsKeepTheirOwnAnchorsAndChangingRootRetiresOldPlacement() {
    var first = ChildElicitationProjection(), second = ChildElicitationProjection()
    first.update(.init(root: "root", turns: ["a"], requests: ["request"]))
    first.update(.init(root: "root", turns: ["a", "b"], requests: ["request"]))
    second.update(.init(root: "root", turns: ["a", "b"], requests: ["request"]))
    XCTAssertEqual(first.entries, [.turn("a"), .child("request", after: "a"), .turn("b")])
    XCTAssertEqual(second.entries, [.turn("a"), .turn("b"), .child("request", after: "b")])
    first.update(.init(root: "other", turns: ["b"], requests: ["request"]))
    XCTAssertEqual(first.entries, [.turn("b"), .child("request", after: "b")])
  }
}
