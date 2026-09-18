import AppKit
import XCTest
@testable import ShipiOS

@MainActor final class PinnedTabRestoreRaceTests: XCTestCase {
  private struct Fixture {
    let store: WorkspaceStore
    let pin: PinnedWorkspaceTab
    let ready: URL
    let release: URL
  }
  private func fixture(kind: PinnedWorkspaceTabKind = .browser) throws -> Fixture {
    _ = NSApplication.shared
    var repository = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    let agent = repository.appendingPathComponent("target/debug/shipios-agent")
    XCTAssertTrue(FileManager.default.isExecutableFile(atPath: agent.path))
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("pin-restore-race-\(UUID())")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: base) }
    let root = GitBranchService.canonicalRoot(base)
    let ready = root.appendingPathComponent("ready"), release = root.appendingPathComponent("release")
    let wrapper = root.appendingPathComponent("gated-agent")
    func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    let script = """
      #!/bin/sh
      : > \(quote(ready.path))
      count=0
      while [ ! -f \(quote(release.path)) ] && [ "$count" -lt 500 ]; do
        /bin/sleep 0.01
        count=$((count+1))
      done
      exec \(quote(agent.path)) "$@"
      """
    try script.write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("data"), agentExecutable: wrapper)
    store.libraryLoaded = true
    store.library.tasks = [.init(id: "main", project: "", title: "Main", runIDs: []),
      .init(id: "source", project: root.path, title: "Source", runIDs: [])]
    store.selection = "main"
    store.library.drafts["main"] = "Retain main draft"
    let pin = PinnedWorkspaceTab(id: "pin", sourceTabID: "\(kind.rawValue):closed", owner: "source",
      kind: kind, title: "Closed", restoreURL: nil, sourceWindowID: "closed-window")
    store.addPinnedWorkspaceTab(pin)
    return Fixture(store: store, pin: pin, ready: ready, release: release)
  }
  private func waitForAgent(_ fixture: Fixture) async throws {
    for _ in 0..<200 {
      if FileManager.default.fileExists(atPath: fixture.ready.path) { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Agent did not reach the gated initialization")
  }

  func testRepeatedRestoreDuringScopeLoadCreatesOneLiveTabAndOneDurablePin() async throws {
    let fixture = try fixture(), store = fixture.store
    let first = Task { await store.openPinnedWorkspaceTab(fixture.pin.id) }
    try await waitForAgent(fixture)
    XCTAssertTrue(store.busy)
    XCTAssertFalse(store.connected)
    await store.openPinnedWorkspaceTab(fixture.pin.id)
    try Data().write(to: fixture.release)
    await first.value
    XCTAssertTrue(store.connected, store.error ?? "")
    XCTAssertEqual(store.workspace.browser.tabs.count, 1)
    XCTAssertEqual(store.workspaceTabs.filter { $0.browserID != nil }.count, 1)
    XCTAssertEqual(store.library.pinnedContentTabs.count, 1)
    XCTAssertEqual(store.library.pinnedContentTabs.first?.sourceTabID, store.activeWorkspaceTabID)
    XCTAssertNil(store.library.pinnedContentTabs.first?.sourceWindowID)
    XCTAssertEqual(store.library.drafts["main"], "Retain main draft")
    await store.shutdown()
  }

  func testUnpinWhileScopeIsLoadingDoesNotCreateOrActivateOrphanContent() async throws {
    let fixture = try fixture(), store = fixture.store
    let first = Task { await store.openPinnedWorkspaceTab(fixture.pin.id) }
    try await waitForAgent(fixture)
    store.unpinWorkspaceTab(fixture.pin.id)
    try Data().write(to: fixture.release)
    await first.value
    XCTAssertTrue(store.connected, store.error ?? "")
    XCTAssertTrue(store.library.pinnedContentTabs.isEmpty)
    XCTAssertTrue(store.workspace.browser.tabs.isEmpty)
    XCTAssertTrue(store.workspaceTabs.isEmpty)
    XCTAssertEqual(store.library.drafts["main"], "Retain main draft")
    await store.shutdown()
  }

  func testRepeatedTerminalRestoreStartsOnlyOneSessionAndSubsequentOpenReusesIt() async throws {
    let fixture = try fixture(kind: .terminal), store = fixture.store
    let first = Task { await store.openPinnedWorkspaceTab(fixture.pin.id) }
    try await waitForAgent(fixture)
    await store.openPinnedWorkspaceTab(fixture.pin.id)
    try Data().write(to: fixture.release)
    await first.value
    XCTAssertTrue(store.connected, store.error ?? "")
    let restoredID = try XCTUnwrap(store.activeBottomWorkspaceContentTab?.terminalID)
    XCTAssertEqual(store.workspaceTabs.filter { $0.terminalID != nil }.count, 1)
    await store.openPinnedWorkspaceTab(fixture.pin.id)
    XCTAssertEqual(store.activeBottomWorkspaceContentTab?.terminalID, restoredID)
    XCTAssertEqual(store.workspaceTabs.filter { $0.terminalID != nil }.count, 1)
    XCTAssertEqual(store.library.pinnedContentTabs.count, 1)
    await store.shutdown()
  }

  func testCancelledRestoreDoesNotCreateContentAndCanBeRetried() async throws {
    let fixture = try fixture(), store = fixture.store
    let first = Task { await store.openPinnedWorkspaceTab(fixture.pin.id) }
    try await waitForAgent(fixture)
    first.cancel()
    try Data().write(to: fixture.release)
    await first.value
    XCTAssertTrue(store.workspace.browser.tabs.isEmpty)
    XCTAssertEqual(store.library.pinnedContentTabs.first, fixture.pin)
    await store.openPinnedWorkspaceTab(fixture.pin.id)
    XCTAssertEqual(store.workspace.browser.tabs.count, 1)
    XCTAssertNil(store.library.pinnedContentTabs.first?.sourceWindowID)
    await store.shutdown()
  }
}
