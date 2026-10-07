import XCTest
@testable import ShipiOS

final class SubagentOverviewTimeTests: XCTestCase {
  private var now: Date { Date(timeIntervalSince1970: 1_800_000_000) }
  private var calendar: Calendar {
    var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!
    return value
  }
  private func agent(_ status: CodexSubagentStatus) -> CodexSubagent {
    .init(rootThreadID: "root", threadID: "child", status: status, loaded: true, observedAtMs: 999)
  }
  func testElapsedReferenceBoundariesTrimZeroUnitsAndClampFutureStarts() {
    for (seconds, label) in [(0, "0s"), (0.999, "0s"), (59, "59s"), (60, "1m"),
      (61, "1m 1s"), (3599, "59m 59s"), (3600, "1h"), (3601, "1h 1s"),
      (3660, "1h 1m"), (86400, "1d"), (90061, "1d 1h 1m 1s"), (-10, "0s")] {
      XCTAssertEqual(SubagentOverviewTime.elapsed(Int((now.timeIntervalSince1970 - seconds) * 1000), now: now), label)
    }
  }
  func testCompactRelativeReferenceUsesMinuteHourAndCalendarThresholds() {
    for (seconds, label) in [(0, "1 分"), (-60, "1 分"), (3599, "59 分"), (3600, "1 小时"),
      (86399, "23 小时"), (86400, "1 天"), (6 * 86400, "6 天"), (7 * 86400, "1 周"),
      (29 * 86400, "4 周"), (30 * 86400, "1 个月"), (364 * 86400, "12 个月"), (365 * 86400, "1 年")] {
      XCTAssertEqual(SubagentOverviewTime.relative(Int((now.timeIntervalSince1970 - Double(seconds)) * 1000),
        now: now, calendar: calendar), label)
    }
    XCTAssertNil(SubagentOverviewTime.relative(-1, now: now, calendar: calendar))
    XCTAssertNil(SubagentOverviewTime.relative(.max, now: now, calendar: calendar))
    var local = calendar; local.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let before = try! XCTUnwrap(local.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 12)))
    let after = try! XCTUnwrap(local.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 12)))
    XCTAssertEqual(SubagentOverviewTime.relative(Int(before.timeIntervalSince1970 * 1000), now: after, calendar: local), "1 周")
  }
  func testTrailingTimeUsesAssistantThenRecencyAndNeverObservationTime() {
    var row = agent(.running)
    XCTAssertEqual(SubagentOverviewTime.trailing(for: row, now: now), [])
    row.startedAtMs = Int(now.timeIntervalSince1970 * 1000) - 61000
    XCTAssertEqual(SubagentOverviewTime.trailing(for: row, now: now), ["1m 1s"])
    XCTAssertEqual(SubagentOverviewTime.trailing(for: row, now: now.addingTimeInterval(1)), ["1m 2s"])
    row.status = .pendingInit
    XCTAssertEqual(SubagentOverviewTime.trailing(for: row, now: now), ["等待中", "1m 1s"])
    row.status = .completed
    XCTAssertEqual(SubagentOverviewTime.trailing(for: row, now: now), [])
    row.recencyAtMs = Int(now.timeIntervalSince1970 * 1000) - 3600000
    row.lastAssistantMessageAtMs = row.recencyAtMs! - 3600000
    XCTAssertEqual(SubagentOverviewTime.trailing(for: row, now: now, calendar: calendar), ["2 小时 前"])
    row.status = .notLoaded
    XCTAssertEqual(SubagentOverviewTime.trailing(for: row, now: now, calendar: calendar), ["2 小时 前"])
    for status in [CodexSubagentStatus.failed, .interrupted, .shutdown] {
      row.status = status; XCTAssertEqual(SubagentOverviewTime.trailing(for: row, now: now), [])
    }
  }
  func testTimingRoundTripAndLegacyMissingFields() throws {
    var row = agent(.completed); row.startedAtMs = 123000; row.lastAssistantMessageAtMs = 123456
    let data = try JSONEncoder().encode(row)
    XCTAssertEqual(try JSONDecoder().decode(CodexSubagent.self, from: data), row)
    var old = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    old.removeValue(forKey: "startedAtMs"); old.removeValue(forKey: "lastAssistantMessageAtMs")
    let restored = try JSONDecoder().decode(CodexSubagent.self, from: JSONSerialization.data(withJSONObject: old))
    XCTAssertNil(restored.startedAtMs); XCTAssertNil(restored.lastAssistantMessageAtMs)
  }
}
