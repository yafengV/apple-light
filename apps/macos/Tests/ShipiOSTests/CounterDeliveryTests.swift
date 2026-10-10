import Foundation
import XCTest

@testable import ShipiOS

@MainActor final class CounterDeliveryTests: XCTestCase {
  private func initial() -> CounterDelivery {
    CounterDelivery(id: UUID(), taskID: "task", project: "/isolated", startedAt: Date())
  }

  private func result(passed: Bool, summary: [String: JSONValue]? = nil,
    changes: JSONValue = .array([]), project: String = "/isolated", status: String? = nil
  ) -> AgentRun {
    AgentRun(id: UUID().uuidString, kind: "verify_counter", project: project,
      status: status ?? (passed ? "succeeded" : "failed"), createdAt: 0, updatedAt: 0,
      request: .object([:]), result: .object([
        "verification": .string(passed ? "passed" : "failed"), "changedInputs": changes,
        "testSummary": .object(summary ?? ["totalTestCount": .number(1),
          "passedTests": .number(passed ? 1 : 0), "failedTests": .number(passed ? 0 : 1),
          "skippedTests": .number(0), "expectedFailures": .number(0)]),
      ]))
  }

  func testFailureStopsAfterExactlyTwoRepairsAndRetainsEveryVerification() async {
    var verifies = 0, prompts: [String] = [], snapshots: [CounterDelivery] = []
    let final = await CounterDeliveryOperation.run(initial(), repairFailures: true,
      verify: { verifies += 1; return self.result(passed: false) },
      repair: { prompts.append($0); return "model-\(prompts.count)" },
      publish: { snapshots.append($0); return true })
    XCTAssertEqual(verifies, 3); XCTAssertEqual(prompts.count, 2)
    XCTAssertEqual(final.phase, .failed); XCTAssertEqual(final.repairs, 2)
    XCTAssertEqual(final.modelRunIDs, ["model-1", "model-2"])
    XCTAssertEqual(final.verifications.count, 3); XCTAssertNotNil(final.finishedAt)
    XCTAssertTrue(prompts[0].contains("第 1/2 轮")); XCTAssertTrue(prompts[1].contains("第 2/2 轮"))
    XCTAssertEqual(snapshots.last, final)
  }

  func testVerifiedSuccessDoesNotAskForRepair() async {
    var repairs = 0
    let final = await CounterDeliveryOperation.run(initial(), repairFailures: true,
      verify: { self.result(passed: true) }, repair: { _ in repairs += 1; return "unexpected" },
      publish: { _ in true })
    XCTAssertEqual(final.phase, .succeeded); XCTAssertEqual(repairs, 0)
    XCTAssertEqual(final.verifications.count, 1)
  }

  func testSuccessAfterFirstRepairStopsLoop() async {
    var verifies = 0
    let final = await CounterDeliveryOperation.run(initial(), repairFailures: true,
      verify: { verifies += 1; return self.result(passed: verifies == 2) },
      repair: { _ in "repair" }, publish: { _ in true })
    XCTAssertEqual(final.phase, .succeeded); XCTAssertEqual(final.repairs, 1)
    XCTAssertEqual(verifies, 2); XCTAssertEqual(final.modelRunIDs, ["repair"])
  }

  func testManualVerificationDoesNotStartModelOnFailure() async {
    var repairs = 0
    let final = await CounterDeliveryOperation.run(initial(), repairFailures: false,
      verify: { self.result(passed: false) }, repair: { _ in repairs += 1; return "bad" },
      publish: { _ in true })
    XCTAssertEqual(final.phase, .failed); XCTAssertEqual(repairs, 0)
  }

  func testMissingCountsSkippedOrChangedSourcesCannotDeclareSuccess() async {
    let candidates = [result(passed: true, summary: [:]),
      result(passed: true, summary: ["totalTestCount": .number(1), "passedTests": .number(1),
        "failedTests": .number(0), "skippedTests": .number(1), "expectedFailures": .number(0)]),
      result(passed: true, changes: .null),
      result(passed: true, changes: .array([.string("HelloShipiOSApp.swift")])),
      result(passed: true, project: "/different")]
    for candidate in candidates {
      let final = await CounterDeliveryOperation.run(initial(), repairFailures: false,
        verify: { candidate }, repair: { _ in XCTFail("Unexpected repair"); return "bad" },
        publish: { _ in true })
      XCTAssertEqual(final.phase, .failed)
    }
  }

  func testCancellationAndStaleOperationNeverStartRepair() async {
    var verifies = 0, repairs = 0
    let stale = await CounterDeliveryOperation.run(initial(), repairFailures: true,
      verify: { verifies += 1; return self.result(passed: false) },
      repair: { _ in repairs += 1; return "bad" }, publish: { _ in false })
    XCTAssertEqual(stale.phase, .cancelled); XCTAssertEqual(verifies, 0)
    let cancelled = await CounterDeliveryOperation.run(initial(), repairFailures: true,
      verify: { throw CancellationError() }, repair: { _ in repairs += 1; return "bad" },
      publish: { _ in true })
    XCTAssertEqual(cancelled.phase, .cancelled); XCTAssertEqual(repairs, 0)
  }

  func testModelFailurePreservesFailedVerificationWithoutRetry() async {
    var verifies = 0
    let final = await CounterDeliveryOperation.run(initial(), repairFailures: true,
      verify: { verifies += 1; return self.result(passed: false) },
      repair: { _ in throw AgentFailure(message: "Disconnected") }, publish: { _ in true })
    XCTAssertEqual(final.phase, .failed); XCTAssertEqual(final.repairs, 1)
    XCTAssertEqual(verifies, 1); XCTAssertEqual(final.verifications.count, 1)
    XCTAssertEqual(final.message, "Disconnected")
  }

  func testRecordsRoundTripAndRestartInterruptsWithoutAutomaticWork() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WorkspaceStore(dataRoot: directory)
    store.libraryLoaded = true
    var record = initial(); record.phase = .repairing; record.repairs = 1
    record.verifications = [result(passed: false)]; record.modelRunIDs = ["model"]
    store.library.counterDeliveries["task"] = record
    let file = directory.appendingPathComponent("workspace.json")
    try store.library.save(to: file)
    store.library = try WorkspaceLibrary.load(from: file)
    XCTAssertEqual(store.library.counterDeliveries["task"], record)
    store.restoreInterruptedChats()
    XCTAssertEqual(store.library.counterDeliveries["task"]?.phase, .interrupted)
    XCTAssertEqual(store.library.counterDeliveries["task"]?.repairs, 1)
    XCTAssertTrue(store.counterDeliveryTasks.isEmpty)
    var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    legacy.removeValue(forKey: "counterDeliveries")
    let restored = try JSONDecoder().decode(WorkspaceLibrary.self,
      from: JSONSerialization.data(withJSONObject: legacy))
    XCTAssertTrue(restored.counterDeliveries.isEmpty)
  }
}
