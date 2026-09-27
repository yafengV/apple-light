import Foundation
import XCTest
@testable import ShipiOS

final class DictationDraftInsertionTests: XCTestCase {
  func testInsertsAtUTF16CaretAndPreservesSurroundingText() {
    let initial = "😀 hello world"
    let selection = NSRange(location: 9, length: 0)
    XCTAssertEqual(DictationDraftInsertion.apply("new", to: initial,
      initial: initial, selection: selection), "😀 hello new world")
  }

  func testReplacesSelectionInUnchangedDraft() {
    XCTAssertEqual(DictationDraftInsertion.apply("新的", to: "hello world",
      initial: "hello world", selection: NSRange(location: 6, length: 5)), "hello 新的")
  }

  func testChangedDraftAppendsInsteadOfOverwritingUserEdits() {
    XCTAssertEqual(DictationDraftInsertion.apply("spoken", to: "draft edited",
      initial: "draft", selection: NSRange(location: 0, length: 5)), "draft edited spoken")
  }

  func testPunctuationAndEmptyTranscriptDoNotAddSpacing() {
    XCTAssertEqual(DictationDraftInsertion.apply("，你好", to: "测试",
      initial: "测试", selection: nil), "测试，你好")
    XCTAssertEqual(DictationDraftInsertion.apply("   ", to: "unchanged",
      initial: "unchanged", selection: nil), "unchanged")
  }
}
