import XCTest
@testable import ShipiOS

final class RunElapsedTimeTests: XCTestCase {
  func testRecordedMillisecondsUseSecondsMinutesAndHours() {
    XCTAssertEqual(RunElapsedTime.title(createdAt: 1000, updatedAt: 50999), "用时 49 秒")
    XCTAssertEqual(RunElapsedTime.title(createdAt: 1000, updatedAt: 1850000), "用时 30 分钟 49 秒")
    XCTAssertEqual(RunElapsedTime.title(createdAt: 1000, updatedAt: 3661000), "用时 1 小时 1 分钟")
  }
  func testInvalidOrOverflowingDatesDoNotInventElapsedTimeOrTrap() {
    XCTAssertNil(RunElapsedTime.title(createdAt: 2000, updatedAt: 1000))
    XCTAssertNil(RunElapsedTime.title(createdAt: .nan, updatedAt: 1000))
    XCTAssertNil(RunElapsedTime.title(createdAt: 0, updatedAt: .infinity))
    XCTAssertNil(RunElapsedTime.title(createdAt: 0, updatedAt: .greatestFiniteMagnitude))
  }
}
