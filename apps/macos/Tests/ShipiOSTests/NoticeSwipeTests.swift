import Foundation
import XCTest
@testable import ShipiOS

final class NoticeSwipeTests: XCTestCase {
  func testActualSonnerPointerTraceMatchesGestureModel() throws {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "notice_swipe_reference", withExtension: "json", subdirectory: "Fixtures"))
    let reference = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    XCTAssertEqual(reference["initialSHA256"] as? String,
      "01c04b2e5a96e5dd4c97e02ffa183f571a55bef7a221abd99404246c430f2212")
    XCTAssertEqual(reference["sourceSHA256"] as? String,
      "6ee362d34edc3538eeab9c0db276847fe30f7d6c7ad868e0e9051235fa7ac8f3")
    let cases = try XCTUnwrap(reference["cases"] as? [String: [String: Any]])
    let plans: [(String, [(CGFloat, CGFloat)], TimeInterval, Bool, Bool)] = [
      ("shortSlow", [(3, 1), (44, 2)], 1, false, false),
      ("shortFast", [(3, 1), (44, 2)], 0.1, false, false),
      ("threshold", [(3, 1), (45, 2)], 1, false, false),
      ("vertical", [(1, 4), (100, 5)], 0.1, false, false),
      ("resistedLeftSlow", [(-3, 1), (-100, 1)], 1, false, false),
      ("resistedLeftFast", [(-3, 1), (-100, 1)], 0.05, false, false),
      ("button", [(3, 1), (100, 2)], 0.05, true, false),
      ("selection", [(3, 1), (100, 2)], 0.05, false, true),
    ]
    for (name, points, elapsed, onButton, selection) in plans {
      let sample = try XCTUnwrap(cases[name], name)
      var swipe = NoticeSwipeGesture()
      swipe.begin(at: 1, onButton: onButton)
      for (x, y) in points { _ = swipe.move(x: x, y: y, selectionActive: selection) }
      let expected = try XCTUnwrap(sample["effective"] as? String)
      let expectedOffset = try XCTUnwrap(Double(expected.replacingOccurrences(of: "px", with: "")))
      XCTAssertEqual(Double(swipe.horizontalOffset), expectedOffset, accuracy: 0.000_001, name)
      XCTAssertEqual(swipe.shouldDismiss(at: 1 + elapsed), sample["dismissed"] as? Int == 1, name)
    }
  }

  func testAxisLocksAndOppositeDirectionIsResisted() {
    var swipe = NoticeSwipeGesture()
    swipe.begin(at: 10, onButton: false)
    XCTAssertEqual(swipe.move(x: 1, y: 1), 0)
    XCTAssertNil(swipe.axis)
    XCTAssertEqual(swipe.move(x: 3, y: 4), 0)
    XCTAssertEqual(swipe.axis, .vertical)
    XCTAssertEqual(swipe.move(x: 100, y: 5), 0)
    XCTAssertFalse(swipe.shouldDismiss(at: 10.01))

    swipe.begin(at: 20, onButton: false)
    XCTAssertEqual(swipe.move(x: -3, y: 1), 0)
    XCTAssertEqual(swipe.axis, .horizontal)
    XCTAssertEqual(swipe.move(x: -100, y: 1), -100 / 6.5, accuracy: 0.000_001)
    XCTAssertFalse(swipe.shouldDismiss(at: 21))
    XCTAssertTrue(swipe.shouldDismiss(at: 20.05))
    XCTAssertTrue(swipe.shouldDismiss(at: 20))
  }
}
