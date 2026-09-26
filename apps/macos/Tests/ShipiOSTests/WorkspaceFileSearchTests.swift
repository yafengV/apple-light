import XCTest
@testable import ShipiOS

@MainActor final class WorkspaceFileSearchTests: XCTestCase {
  private func result(_ path: String, directory: Bool = false) -> WorkspaceFileSearchResult {
    .init(path: path, isDirectory: directory, score: 100)
  }
  private func request(_ query: String) -> WorkspaceFileSearchRequest {
    .init(root: URL(fileURLWithPath: "/tmp"), query: query, executable: URL(fileURLWithPath: "/unused"))
  }

  func testFilenameRankingRetainsPathOnlyCandidatesAndFiltersExcludedComponents() {
    let input = [result("CommandPaletteView/Z.swift"), result("Sources/CommandPaletteViewExtra.swift"),
      result("B/CommandPaletteView.swift"), result("A/CommandPaletteView.swift"),
      result("node_modules/CommandPaletteView.swift"), result("build/CommandPaletteView.swift"),
      result("Sources", directory: true), result(".config/CommandPaletteView.swift")]
    let ranked = WorkspaceFileSearchResult.ranked(input, query: "cpv")
    XCTAssertEqual(ranked.map(\.path), ["B/CommandPaletteView.swift", "A/CommandPaletteView.swift",
      ".config/CommandPaletteView.swift", "Sources/CommandPaletteViewExtra.swift", "Sources", "CommandPaletteView/Z.swift"])
    XCTAssertEqual(ranked[0].title, "CommandPaletteView.swift")
    XCTAssertEqual(ranked[0].directory, "B")
    XCTAssertTrue(ranked[4].isDirectory)
  }

  func testBlankQueryNeverInvokesLoaderAndClearsPreviousResults() async {
    let catalog = WorkspaceFileSearchCatalog()
    let item = result("File.swift")
    await catalog.search(request("file")) { _ in [item] }
    XCTAssertEqual(catalog.results, [item])
    await catalog.search(request(" \n ")) { _ in XCTFail("Empty search must not scan disk"); return [] }
    XCTAssertTrue(catalog.results.isEmpty)
    XCTAssertFalse(catalog.searching)
  }

  func testOutOfOrderSearchAndCancelledResponsesCannotReplaceCurrentResults() async {
    let catalog = WorkspaceFileSearchCatalog(), gate = FileSearchGate()
    let oldRequest = request("old"), newRequest = request("new")
    let old = Task { await catalog.search(oldRequest) { try await gate.load($0.query) } }
    await gate.started("old")
    let new = Task { await catalog.search(newRequest) { try await gate.load($0.query) } }
    await gate.started("new")
    let current = result("new.swift")
    await gate.finish("new", result: [current])
    await new.value
    await gate.finish("old", result: [result("old.swift")])
    await old.value
    XCTAssertEqual(catalog.results, [current])
    XCTAssertEqual(catalog.results(for: newRequest), [current])
    XCTAssertTrue(catalog.results(for: oldRequest).isEmpty)
    XCTAssertEqual(catalog.request, newRequest)
    let cancelled = Task { await catalog.search(oldRequest) { _ in try await gate.load("cancelled") } }
    await gate.started("cancelled")
    cancelled.cancel()
    await gate.finish("cancelled", result: [result("old.swift")])
    await cancelled.value
    XCTAssertEqual(catalog.results, [current], "Keep the last displayed results while replacing a query; ignore late cancelled output")
    XCTAssertNil(catalog.error)
    XCTAssertFalse(catalog.searching)
  }

  func testChangingQueryHidesOldResultsUntilNewCandidatesArrive() async {
    let catalog = WorkspaceFileSearchCatalog(), gate = FileSearchGate()
    let oldRequest = request("old"), newRequest = request("new")
    let oldResult = result("old.swift"), newResult = result("new.swift")
    await catalog.search(oldRequest) { _ in [oldResult] }
    XCTAssertEqual(catalog.results(for: oldRequest), [oldResult])
    XCTAssertTrue(catalog.results(for: newRequest).isEmpty,
      "The input changes before the replacement task starts; Return must not open the old file")
    let new = Task { await catalog.search(newRequest) { try await gate.load($0.query) } }
    await gate.started("new")
    XCTAssertEqual(catalog.results, [oldResult], "Keep cached results internally while replacement search loads")
    XCTAssertTrue(catalog.results(for: newRequest).isEmpty,
      "The search task started, but no candidates belong to the new query yet")
    await gate.finish("new", result: [newResult])
    await new.value
    XCTAssertEqual(catalog.results(for: newRequest), [newResult])
    XCTAssertTrue(catalog.results(for: oldRequest).isEmpty)
  }

  func testErrorCanBeRetriedAndDirectoryDestinationIsValidated() async throws {
    let catalog = WorkspaceFileSearchCatalog(), request = request("folder")
    await catalog.search(request) { _ in throw AgentFailure(message: "test failure") }
    XCTAssertEqual(catalog.error, "test failure")
    let item = result("Sources", directory: true)
    await catalog.search(request) { _ in [item] }
    XCTAssertNil(catalog.error)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
    XCTAssertEqual(try item.directoryURL(root: root), root.appendingPathComponent("Sources").resolvingSymlinksInPath())
    XCTAssertThrowsError(try result("Missing", directory: true).directoryURL(root: root))
    XCTAssertThrowsError(try result("../", directory: true).directoryURL(root: root))
  }

  func testHelperCommandCancellationStopsWaitingForChildExit() async throws {
    let began = Date()
    let task = Task { try await LocalWorkspaceService.command("/bin/sleep", ["10"],
      at: FileManager.default.temporaryDirectory, cancelWithTask: true) }
    try await Task.sleep(for: .milliseconds(150))
    task.cancel()
    do { _ = try await task.value; XCTFail("Cancelled helper must throw") }
    catch is CancellationError {}
    XCTAssertLessThan(Date().timeIntervalSince(began), 3)
  }
}

private actor FileSearchGate {
  private var pending: [String: CheckedContinuation<[WorkspaceFileSearchResult], Error>] = [:]
  private var waiters: [String: CheckedContinuation<Void, Never>] = [:]
  func load(_ query: String) async throws -> [WorkspaceFileSearchResult] {
    try await withCheckedThrowingContinuation { continuation in
      pending[query] = continuation
      waiters.removeValue(forKey: query)?.resume()
    }
  }
  func started(_ query: String) async {
    if pending[query] != nil { return }
    await withCheckedContinuation { waiters[query] = $0 }
  }
  func finish(_ query: String, result: [WorkspaceFileSearchResult]) {
    pending.removeValue(forKey: query)?.resume(returning: result)
  }
}
