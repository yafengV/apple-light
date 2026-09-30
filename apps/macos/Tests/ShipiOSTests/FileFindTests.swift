import XCTest
@testable import ShipiOS

final class FileFindTests: XCTestCase {
  func testLiteralSearchUsesUTF16RangesCaseAndWholeWords() {
    let source = "👩🏽‍💻 café Cafe cafeteria CAFE"
    let plain = FileFindEngine.find("cafe", in: source, options: .init())
    XCTAssertEqual(plain.ranges.count, 3)
    XCTAssertEqual((source as NSString).substring(with: plain.ranges[0]), "Cafe")
    var options = FileFindOptions()
    options.wholeWord = true
    XCTAssertEqual(FileFindEngine.find("cafe", in: source, options: options).ranges.count, 2)
    options.matchCase = true
    XCTAssertEqual(FileFindEngine.find("cafe", in: source, options: options).ranges.count, 0)
  }

  func testRegexSearchAndReplacementPreserveCaptureGroups() {
    var options = FileFindOptions()
    options.regularExpression = true
    let source = "row 12 / row 34"
    let result = FileFindEngine.find("row (\\d+)", in: source, options: options)
    XCTAssertEqual(result.ranges.count, 2)
    XCTAssertEqual(FileFindEngine.replacing(result.ranges[0], in: source,
      query: "row (\\d+)", with: "line $1", options: options), "line 12")
    XCTAssertEqual(FileFindEngine.replacingAll(in: source, query: "row (\\d+)",
      with: "line $1", options: options), "line 12 / line 34")
    XCTAssertNotNil(FileFindEngine.find("[", in: source, options: options).error)
  }

  func testLiteralReplacementTreatsDollarSignsAsText() {
    let source = "a a"
    let options = FileFindOptions()
    XCTAssertEqual(FileFindEngine.replacingAll(in: source, query: "a", with: "$1", options: options), "$1 $1")
  }
}
