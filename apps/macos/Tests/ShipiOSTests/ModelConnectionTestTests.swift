import XCTest
@testable import ShipiOS

final class ModelConnectionTestTests: XCTestCase {
  @MainActor private func config(_ address: String) -> ModelConfiguration {
    var config = ModelConfiguration()
    config.baseURL = address
    config.model = "fixture-model"
    return config
  }

  @MainActor func testChangedServiceDiscardsLateResultEvenWhenTransportIgnoresCancellation() async {
    let connection = ModelConnectionTest()
    let started = expectation(description: "Old request started")
    var reply: CheckedContinuation<Int, Never>?
    let original = config("http://127.0.0.1:1234/v1")
    connection.start(config: original) { captured in
      XCTAssertEqual(captured, original)
      return await withCheckedContinuation { reply = $0; started.fulfill() }
    }
    await fulfillment(of: [started], timeout: 2)
    connection.invalidateIfChanged(config: config("http://127.0.0.1:1/v1"), keyDraft: "")
    XCTAssertFalse(connection.testing)
    reply?.resume(returning: 1)
    for _ in 0..<10 { await Task.yield() }
    XCTAssertEqual(connection.status, "")
    XCTAssertFalse(connection.testing)
  }

  @MainActor func testOldReplyCannotFinishOrOverwriteNewRequestAndKeyChangesInvalidateIt() async {
    let connection = ModelConnectionTest()
    let firstStarted = expectation(description: "First request started")
    let secondStarted = expectation(description: "Second request started")
    var first: CheckedContinuation<Int, Never>?
    var second: CheckedContinuation<Int, Never>?
    let service = config("http://127.0.0.1:1234/v1")
    connection.start(config: service) { _ in
      await withCheckedContinuation { first = $0; firstStarted.fulfill() }
    }
    await fulfillment(of: [firstStarted], timeout: 2)
    connection.start(config: service) { _ in
      await withCheckedContinuation { second = $0; secondStarted.fulfill() }
    }
    await fulfillment(of: [secondStarted], timeout: 2)
    first?.resume(returning: 99)
    for _ in 0..<10 { await Task.yield() }
    XCTAssertTrue(connection.testing)
    XCTAssertEqual(connection.status, "")
    connection.invalidateIfChanged(config: service, keyDraft: "")
    XCTAssertTrue(connection.testing, "Unchanged draft must not cancel its request")
    second?.resume(returning: 2)
    for _ in 0..<100 where connection.testing { await Task.yield() }
    XCTAssertFalse(connection.testing)
    XCTAssertEqual(connection.status, "模型列表可用，服务返回 2 个模型。")
    connection.invalidateIfChanged(config: service, keyDraft: "fixture-only")
    XCTAssertEqual(connection.status, "")
  }

  @MainActor func testFailureEndsLoadingAndExplicitCancelClearsCompletedStatus() async {
    let connection = ModelConnectionTest()
    connection.start(config: config("http://127.0.0.1:1/v1")) { _ in
      throw AgentFailure(message: "Controlled connection failure")
    }
    for _ in 0..<100 where connection.testing { await Task.yield() }
    XCTAssertFalse(connection.testing)
    XCTAssertEqual(connection.status, "Controlled connection failure")
    connection.cancel()
    XCTAssertEqual(connection.status, "")
    connection.start(config: config("http://127.0.0.1:1234/v1")) { _ in 1 }
    for _ in 0..<100 where connection.testing { await Task.yield() }
    XCTAssertFalse(connection.testing)
    XCTAssertEqual(connection.status, "模型列表可用，服务返回 1 个模型。")
  }
}
