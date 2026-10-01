import XCTest
@testable import ShipiOS

final class SpeechRecognitionCompletionTests: XCTestCase {
  func testFinalResultAfterReleaseReplacesPartialText() {
    var completion = SpeechRecognitionCompletion()
    XCTAssertFalse(completion.receive("你好", isFinal: false, hasError: false))
    XCTAssertTrue(completion.beginFinishing())
    XCTAssertFalse(completion.beginFinishing())
    XCTAssertFalse(completion.receive("你好世", isFinal: false, hasError: false))
    XCTAssertTrue(completion.receive("你好世界。", isFinal: true, hasError: false))
    XCTAssertEqual(completion.stop(), "你好世界。")
    XCTAssertFalse(completion.finishAfterTimeout(), "A late timeout cannot commit a second time")
  }

  func testTimeoutUsesLatestPartialAndRejectsLateResult() {
    var completion = SpeechRecognitionCompletion()
    XCTAssertFalse(completion.finishAfterTimeout())
    XCTAssertFalse(completion.receive("  一句话  ", isFinal: false, hasError: false))
    XCTAssertTrue(completion.beginFinishing())
    XCTAssertTrue(completion.finishAfterTimeout())
    XCTAssertFalse(completion.receive("迟到的最终结果", isFinal: true, hasError: false))
    XCTAssertEqual(completion.stop(), "一句话")
  }

  func testErrorCompletesWithAvailablePartial() {
    var completion = SpeechRecognitionCompletion()
    XCTAssertFalse(completion.receive("已经识别", isFinal: false, hasError: false))
    XCTAssertTrue(completion.beginFinishing())
    XCTAssertTrue(completion.receive(nil, isFinal: false, hasError: true))
    XCTAssertEqual(completion.stop(), "已经识别")
    XCTAssertFalse(completion.finishAfterTimeout())
  }
}
