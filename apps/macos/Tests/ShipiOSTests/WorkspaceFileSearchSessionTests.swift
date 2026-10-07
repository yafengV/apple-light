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

  func testBundledAgentCompletesARealSearchWhenProvided() async throws {
    let executable = try AgentTestExecutable.url()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data().write(to: root.appendingPathComponent("AlphaBeta.swift"))
    let session = try WorkspaceFileSearchSession(root: root, executable: executable)
    defer { session.close() }
    var updates: [WorkspaceFileSearchUpdate] = []
    for try await update in try session.query("ab") { updates.append(update) }
    XCTAssertEqual(updates.last?.complete, true)
    XCTAssertEqual(updates.last?.files.map(\.path), ["AlphaBeta.swift"])
  }

  func testPartialResultsKeepAWorkingSearchAlive() async throws {
    try await verifyPartialResultsKeepAlive(delayedStartup: false)
  }

  func testPartialResultsKeepAliveAfterSlowFixtureStartup() async throws {
    try await verifyPartialResultsKeepAlive(delayedStartup: true)
  }

  private func verifyPartialResultsKeepAlive(delayedStartup: Bool) async throws {
    let root = try fixture("""
    \(delayedStartup ? "/bin/sleep 0.6" : ":")
    printf '' > boot
    read query
    printf '' > query-read
    for value in 1 2 3 4 5; do
      printf '{"id":1,"files":[],"complete":false}\\n'
      printf '' > "emitted-$value"
      /bin/sleep 0.15
    done
    printf '{"id":1,"files":[],"complete":true}\\n'
    printf '' > emitted-complete
    while read query; do :; done
    """)
    defer { try? FileManager.default.removeItem(at: root) }
    let launchStarted = Date()
    let session = try WorkspaceFileSearchSession(root: root, executable: root.appendingPathComponent("helper"),
      timeout: .milliseconds(400))
    defer { session.close() }
    // This verifies progress renewing a query deadline, not how quickly macOS
    // schedules the new shell. Keep fixture readiness separately bounded and
    // leave the transport's 400 ms query timeout unchanged.
    let boot = root.appendingPathComponent("boot").path
    let readyDeadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !FileManager.default.fileExists(atPath: boot), ContinuousClock.now < readyDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    guard FileManager.default.fileExists(atPath: boot) else {
      XCTFail("File-search fixture did not become ready within 3 seconds")
      return
    }
    let queryStarted = Date()
    var updates: [WorkspaceFileSearchUpdate] = []
    var received: [TimeInterval] = []
    do {
      for try await update in try session.query("value") {
        updates.append(update); received.append(Date().timeIntervalSince(queryStarted))
      }
    } catch {
      let milestones = (["boot", "query-read"] + (1...5).map { "emitted-\($0)" } + ["emitted-complete"]).map { name in
        let attributes = try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(name).path)
        let time = (attributes?[.modificationDate] as? Date)?.timeIntervalSince(queryStarted)
        return name + "=" + (time.map { String(format: "%.4f", $0) } ?? "missing")
      }
      XCTFail("\(error); query elapsed=\(Date().timeIntervalSince(queryStarted)), launchAndReadiness=\(queryStarted.timeIntervalSince(launchStarted)), received=\(received), child=\(milestones)")
      return
    }
    XCTAssertEqual(updates.map(\.complete), [false, false, false, false, false, true])
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

  func testReadyOldDeadlineCannotFailAQueryThatAlreadyReceivedProgress() async throws {
    let root = try fixture("""
    read query
    while [ ! -e progress ]; do /bin/sleep 0.01; done
    printf '{"id":1,"files":[],"complete":false}\\n'
    while [ ! -e complete ]; do /bin/sleep 0.01; done
    printf '{"id":1,"files":[],"complete":true}\\n'
    while read query; do :; done
    """)
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = SearchDeadlineFixture()
    addTeardownBlock { await clock.releaseAll() }
    let session = try WorkspaceFileSearchSession(root: root, executable: root.appendingPathComponent("helper"),
      timeoutSleep: { await clock.sleep($0) })
    defer { session.close() }
    let partial = expectation(description: "real helper progress")
    var finished = false
    let pending = Task { () -> Result<[Bool], Error> in
      defer { finished = true }
      do {
        var updates: [Bool] = []
        for try await update in try session.query("value") {
          updates.append(update.complete)
          if !update.complete { partial.fulfill() }
        }
        return .success(updates)
      } catch { return .failure(error) }
    }
    try await clock.started(1)
    try Data().write(to: root.appendingPathComponent("progress"))
    await fulfillment(of: [partial], timeout: 3)
    try await clock.started(2)
    // Model a sleep whose deadline was ready before cancellation, but whose
    // task resumes on the main actor after the new progress was processed.
    await clock.release(0)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertFalse(finished, "An obsolete timeout must not terminate the current search")
    try Data().write(to: root.appendingPathComponent("complete"))
    let updates = try await pending.value.get()
    XCTAssertEqual(updates, [false, true])
    await clock.releaseAll()
  }

  func testDeadlineProcessesAlreadyReadProgressBeforeFailing() async throws {
    let root = try fixture("""
    read query
    printf '{"id":1,"files":[],"complete":false}\\n'
    while read query; do :; done
    """)
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = SearchDeadlineFixture(), delivery = SearchDeadlineFixture()
    addTeardownBlock { await clock.releaseAll(); await delivery.releaseAll() }
    let session = try WorkspaceFileSearchSession(root: root, executable: root.appendingPathComponent("helper"),
      timeoutSleep: { await clock.sleep($0) }, beforeResponseDelivery: { await delivery.sleep(.zero) })
    defer { session.close() }
    let partial = expectation(description: "already-read progress")
    var observed: [Bool] = []
    let pending = Task { () -> Error? in
      do {
        for try await update in try session.query("value") {
          observed.append(update.complete)
          if !update.complete { partial.fulfill() }
        }
        return nil
      } catch { return error }
    }
    try await clock.started(1)
    // The real pipe has been read, but its ordinary actor delivery is held.
    // Let timeout be the next actor job to inspect the session.
    try await delivery.started(1)
    await clock.release(0)
    await fulfillment(of: [partial], timeout: 1)
    XCTAssertEqual(observed, [false])
    session.cancelQuery()
    let error = await pending.value
    XCTAssertTrue(error is CancellationError, "Read progress must keep the query alive until explicit cancellation")
    await delivery.releaseAll(); await clock.releaseAll()
  }

  func testDeadlineProcessesAlreadyReadCompletionBeforeFailing() async throws {
    let root = try fixture("""
    read query
    printf '{"id":1,"files":[],"complete":true}\\n'
    while read query; do :; done
    """)
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = SearchDeadlineFixture(), delivery = SearchDeadlineFixture()
    addTeardownBlock { await clock.releaseAll(); await delivery.releaseAll() }
    let session = try WorkspaceFileSearchSession(root: root, executable: root.appendingPathComponent("helper"),
      timeoutSleep: { await clock.sleep($0) }, beforeResponseDelivery: { await delivery.sleep(.zero) })
    defer { session.close() }
    let pending = Task { () -> Result<[Bool], Error> in
      do {
        var observed: [Bool] = []
        for try await update in try session.query("value") { observed.append(update.complete) }
        return .success(observed)
      } catch { return .failure(error) }
    }
    try await clock.started(1); try await delivery.started(1)
    await clock.release(0)
    let observed = try await pending.value.get()
    XCTAssertEqual(observed, [true])
    await delivery.releaseAll(); await clock.releaseAll()
  }

  func testBufferedProgressRenewsDeadlineButLaterSilenceStillTimesOut() async throws {
    let root = try fixture("""
    read query
    printf '{"id":1,"files":[],"complete":false}\\n'
    while read query; do :; done
    """)
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = SearchDeadlineFixture(), delivery = SearchDeadlineFixture()
    addTeardownBlock { await clock.releaseAll(); await delivery.releaseAll() }
    let session = try WorkspaceFileSearchSession(root: root, executable: root.appendingPathComponent("helper"),
      timeoutSleep: { await clock.sleep($0) }, beforeResponseDelivery: { await delivery.sleep(.zero) })
    defer { session.close() }
    let partial = expectation(description: "progress renews deadline")
    let pending = Task { () -> Error? in
      do {
        for try await update in try session.query("value") { if !update.complete { partial.fulfill() } }
        return nil
      } catch { return error }
    }
    try await clock.started(1); try await delivery.started(1)
    await clock.release(0)
    await fulfillment(of: [partial], timeout: 1)
    try await clock.started(2)
    await clock.release(1)
    let error = await pending.value
    XCTAssertTrue(error?.localizedDescription.contains("超时") == true)
    XCTAssertThrowsError(try session.query("after timeout"))
    await delivery.releaseAll(); await clock.releaseAll()
  }

  func testCoalescedWakeupsRetainEveryRealPipeFrameInOrder() async throws {
    let root = try fixture("""
    read query
    value=0
    while [ "$value" -lt 512 ]; do
      value=$((value + 1))
      printf '{"id":1,"files":[{"path":"File%s.swift","isDirectory":false,"score":1}],"complete":false}\\n' "$value"
    done
    printf '{"id":1,"files":[],"complete":true}\\n'
    while read query; do :; done
    """)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try WorkspaceFileSearchSession(root: root, executable: root.appendingPathComponent("helper"))
    defer { session.close() }
    var updates: [WorkspaceFileSearchUpdate] = []
    for try await update in try session.query("value") { updates.append(update) }
    XCTAssertEqual(updates.count, 513)
    XCTAssertEqual(updates.last?.complete, true)
    XCTAssertEqual(updates.flatMap(\.files).map(\.path), (1...512).map { "File\($0).swift" })
  }

  func testReadyDeadlineIgnoresStaleFramesAndReportsBufferedProtocolErrors() async throws {
    for (frame, expected) in [("{\"id\":0,\"files\":[],\"complete\":false}", "超时"), ("not-json", "无效")] {
      let root = try fixture("read query; printf '%s\\n' '" + frame + "'; while read query; do :; done")
      defer { try? FileManager.default.removeItem(at: root) }
      let clock = SearchDeadlineFixture(), delivery = SearchDeadlineFixture()
      addTeardownBlock { await clock.releaseAll(); await delivery.releaseAll() }
      let session = try WorkspaceFileSearchSession(root: root, executable: root.appendingPathComponent("helper"),
        timeoutSleep: { await clock.sleep($0) }, beforeResponseDelivery: { await delivery.sleep(.zero) })
      defer { session.close() }
      let pending = Task { () -> Error? in
        do { for try await _ in try session.query("value") {}; return nil }
        catch { return error }
      }
      try await clock.started(1); try await delivery.started(1)
      await clock.release(0)
      let error = await pending.value
      XCTAssertTrue(error?.localizedDescription.contains(expected) == true, error?.localizedDescription ?? "Missing failure")
      XCTAssertThrowsError(try session.query("after failure"))
      await delivery.releaseAll(); await clock.releaseAll()
    }
  }

  func testReplacementQueryCancelsOldDeadlineBeforeDebouncingWithoutRestartingIndex() async throws {
    let root = try fixture("exit 0")
    defer { try? FileManager.default.removeItem(at: root) }
    let helper = root.appendingPathComponent("helper")
    try Data("""
    #!/usr/bin/python3
    import json, sys
    for line in sys.stdin:
        query = json.loads(line)
        with open('queries.jsonl', 'a') as log:
            log.write(json.dumps(query) + '\\n')
        if query['query'] == 'next':
            print(json.dumps({'id': query['id'], 'files': [
                {'path': 'Next.swift', 'isDirectory': False, 'score': 10}
            ], 'complete': True}), flush=True)
    """.utf8).write(to: helper)
    let clock = SearchDeadlineFixture()
    addTeardownBlock { await clock.releaseAll() }
    let session = try WorkspaceFileSearchSession(root: root, executable: helper,
      timeoutSleep: { await clock.sleep($0) })
    let pid = session.processIdentifier
    var creations = 0
    let catalog = WorkspaceFileSearchCatalog { _ in creations += 1; return session }
    defer { catalog.close() }
    let firstRequest = request("first", root: root.path)
    let nextRequest = request("next", root: root.path)
    let first = Task { await catalog.search(firstRequest) }
    try await clock.started(1)
    let ready = ContinuousClock.now.advanced(by: .seconds(3))
    while !FileManager.default.fileExists(atPath: root.appendingPathComponent("queries.jsonl").path),
      ContinuousClock.now < ready { try await Task.sleep(for: .milliseconds(1)) }
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("queries.jsonl").path),
      "Observe the helper accepting the first query before testing replacement")
    let complete = expectation(description: "replacement query completes")
    let next = Task { await catalog.search(nextRequest); complete.fulfill() }
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while catalog.request != nextRequest, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(1))
    }
    XCTAssertEqual(catalog.request, nextRequest)
    // Expire the original real transport while the replacement is still in its
    // debounce. It must already have cancelled the original query and deadline.
    await clock.release(0)
    await fulfillment(of: [complete], timeout: 3)
    XCTAssertNil(catalog.error)
    XCTAssertEqual(catalog.results(for: nextRequest).map(\.path), ["Next.swift"])
    XCTAssertFalse(catalog.searching)
    XCTAssertEqual(creations, 1, "Typing must retain the existing read-only index")
    XCTAssertEqual(session.processIdentifier, pid)
    let log = try String(contentsOf: root.appendingPathComponent("queries.jsonl"), encoding: .utf8)
      .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    XCTAssertEqual(log.compactMap { $0?["query"] as? String }, ["first", "", "next"])
    catalog.close()
    await first.value; await next.value
    await clock.releaseAll()
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

private actor SearchDeadlineFixture {
  private var count = 0
  private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
  func sleep(_ duration: Duration) async {
    let index = count; count += 1
    await withCheckedContinuation { waiters[index] = $0 }
  }
  func started(_ expected: Int) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while count < expected {
      guard ContinuousClock.now < deadline else { throw AgentFailure(message: "Search deadline did not start") }
      try await Task.sleep(for: .milliseconds(1))
    }
  }
  func release(_ index: Int) { waiters.removeValue(forKey: index)?.resume() }
  func releaseAll() { let pending = waiters; waiters = [:]; for waiter in pending.values { waiter.resume() } }
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
