import Observation
import XCTest
@testable import ShipiOS

@MainActor final class WorkspaceFileSearchSessionTests: XCTestCase {
  private func request(_ query: String, root: String = "/tmp/first") -> WorkspaceFileSearchRequest {
    .init(root: URL(fileURLWithPath: root), query: query, executable: URL(fileURLWithPath: "/unused"))
  }
  private let first = WorkspaceFileSearchResult(path: "AlphaBeta.swift", isDirectory: false, score: 100)
  private let second = WorkspaceFileSearchResult(path: "AlphaBravo.swift", isDirectory: false, score: 90)

  func testPartialResultsStayUsableUntilCompletionAndNextQueryReusesSession() async {
    let session = SearchSessionFixture()
    var creations = 0
    let catalog = WorkspaceFileSearchCatalog { _ in creations += 1; return session }
    let search = Task { await catalog.search(request("ab")) }
    await session.started("ab")
    let partial = expectation(description: "partial results")
    withObservationTracking { _ = catalog.results } onChange: { partial.fulfill() }
    session.emit([first], complete: false)
    await fulfillment(of: [partial], timeout: 1)
    XCTAssertEqual(catalog.results, [first])
    XCTAssertEqual(catalog.results(for: request("ab")), [first])
    XCTAssertTrue(catalog.searching)
    session.emit([first, second], complete: true)
    await search.value
    XCTAssertFalse(catalog.searching)
    XCTAssertEqual(catalog.results.count, 2)
    let next = Task { await catalog.search(request("bravo")) }
    await session.started("bravo")
    XCTAssertEqual(catalog.results.count, 2, "Keep the old candidates internally while the next query loads")
    XCTAssertTrue(catalog.results(for: request("bravo")).isEmpty,
      "The visible list must not offer stale files for Return during a replacement query")
    XCTAssertTrue(catalog.searching)
    session.emit([second], complete: true)
    await next.value
    XCTAssertEqual(creations, 1)
    XCTAssertEqual(catalog.results, [second])
    XCTAssertEqual(catalog.results(for: request("bravo")), [second])
    await catalog.search(request(" "))
    XCTAssertTrue(catalog.results.isEmpty)
    XCTAssertEqual(session.cancellations, 1)
    XCTAssertEqual(session.closes, 0)
    catalog.close()
    XCTAssertEqual(session.closes, 1)
  }

  func testRootChangeAndExplicitRetryReplaceIndexAndCloseFinishesPendingSearch() async {
    let firstSession = SearchSessionFixture(), secondSession = SearchSessionFixture(), retrySession = SearchSessionFixture()
    var sessions = [firstSession, secondSession, retrySession]
    let catalog = WorkspaceFileSearchCatalog { _ in sessions.removeFirst() }
    let old = Task { await catalog.search(request("ab")) }
    await firstSession.started("ab")
    let newRequest = request("ab", root: "/tmp/second")
    let next = Task { await catalog.search(newRequest) }
    await secondSession.started("ab")
    await old.value
    XCTAssertEqual(firstSession.closes, 1)
    secondSession.emit([second], complete: true)
    await next.value
    var retry = newRequest; retry.retry = 1
    let last = Task { await catalog.search(retry) }
    await retrySession.started("ab")
    XCTAssertEqual(secondSession.closes, 1)
    catalog.close()
    await last.value
    XCTAssertEqual(retrySession.closes, 1)
    XCTAssertNil(catalog.request)
    XCTAssertNil(catalog.error)
    XCTAssertTrue(catalog.results.isEmpty)
    XCTAssertFalse(catalog.searching)
  }

  func testNativeTransportAcceptsSplitFramesAndIgnoresOldQueryIDs() async throws {
    let root = try fixture("""
    read query
    printf '%s\\n' '{"id":0,"files":[{"path":"stale.swift","isDirectory":false,"score":1}],"complete":true}'
    printf '%s' '{"id":1,"files":['
    /bin/sleep 0.03
    printf '%s\\n' '{"path":"Alpha.swift","isDirectory":false,"score":10}],"complete":false}'
    /bin/sleep 0.03
    printf '%s\\n' '{"id":1,"files":[{"path":"Alpha.swift","isDirectory":false,"score":10}],"complete":true}'
    while read query; do :; done
    """)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try WorkspaceFileSearchSession(root: root, executable: root.appendingPathComponent("helper"))
    defer { session.close() }
    var updates: [WorkspaceFileSearchUpdate] = []
    for try await update in try session.query("alpha") { updates.append(update) }
    XCTAssertEqual(updates.map(\.complete), [false, true])
    XCTAssertEqual(updates.flatMap(\.files).map(\.path), ["Alpha.swift", "Alpha.swift"])
  }

  func testTimeoutAndMalformedFramesFailWithoutLeavingLoadingPending() async throws {
    for (body, expected) in [("exec /bin/sleep 10", "超时"), ("read query; printf 'not-json\\n'", "无效"), ("exit 0", "已退出")] {
      let root = try fixture(body)
      defer { try? FileManager.default.removeItem(at: root) }
      let session = try WorkspaceFileSearchSession(root: root, executable: root.appendingPathComponent("helper"),
        timeout: expected == "超时" ? .milliseconds(100) : .seconds(2))
      defer { session.close() }
      do {
        for try await _ in try session.query("value") {}
        XCTFail("Failed transport must report an error")
      } catch { XCTAssertTrue(error.localizedDescription.contains(expected), error.localizedDescription) }
      XCTAssertThrowsError(try session.query("again"))
    }
  }

  private func fixture(_ body: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let helper = root.appendingPathComponent("helper")
    try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: helper)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    return root
  }
}

@MainActor private final class SearchSessionFixture: FileSearchSession {
  var closes = 0, cancellations = 0
  private var current = ""
  private var pending: AsyncThrowingStream<WorkspaceFileSearchUpdate, Error>.Continuation?
  private var waiters: [String: CheckedContinuation<Void, Never>] = [:]
  func query(_ text: String) throws -> AsyncThrowingStream<WorkspaceFileSearchUpdate, Error> {
    pending?.finish(throwing: CancellationError())
    current = text
    let (stream, emitter) = AsyncThrowingStream<WorkspaceFileSearchUpdate, Error>.makeStream()
    pending = emitter
    waiters.removeValue(forKey: text)?.resume()
    return stream
  }
  func started(_ text: String) async {
    if current == text, pending != nil { return }
    await withCheckedContinuation { waiters[text] = $0 }
  }
  func emit(_ files: [WorkspaceFileSearchResult], complete: Bool) {
    pending?.yield(.init(id: 1, files: files, complete: complete))
    if complete { pending?.finish(); pending = nil }
  }
  func cancelQuery() { cancellations += 1; pending?.finish(throwing: CancellationError()); pending = nil }
  func close() { closes += 1; pending?.finish(throwing: CancellationError()); pending = nil }
}
