import XCTest
@testable import ShipiOS

@MainActor final class CommandBrowserScopeTests: XCTestCase {
  private struct Fixture {
    let store: WorkspaceStore
    let base: URL, source: URL, other: URL, ready: URL, release: URL
    let result: CommandBrowserResult
    let page: BrowserTab
  }
  private func fixture() async throws -> Fixture {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("browser-search-scope-\(UUID())")
      .resolvingSymlinksInPath().standardizedFileURL
    let source = base.appendingPathComponent("Source"), other = base.appendingPathComponent("Other")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    let ready = base.appendingPathComponent("ready"), release = base.appendingPathComponent("release")
    let wrapper = base.appendingPathComponent("gated-agent"), agent = try AgentTestExecutable.url()
    func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    try """
      #!/bin/sh
      : > \(quote(ready.path))
      count=0
      while [ ! -f \(quote(release.path)) ] && [ "$count" -lt 500 ]; do
        /bin/sleep 0.01
        count=$((count+1))
      done
      exec \(quote(agent.path)) "$@"
      """.write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    try Data().write(to: release)
    let store = WorkspaceStore(dataRoot: base.appendingPathComponent("Data"), agentExecutable: wrapper)
    addTeardownBlock { @MainActor in await store.shutdown(); try? FileManager.default.removeItem(at: base) }
    await store.restore(); await store.open(source)
    XCTAssertTrue(store.connected, store.error ?? "")
    store.newTask(); store.draft = "Source unsent input"; store.newBrowserTab()
    let page = try XCTUnwrap(store.workspace.browser.selected), result = try XCTUnwrap(store.commandBrowserTabs.first)
    await store.open(other); store.newTask(); store.draft = "Other unsent input"
    XCTAssertTrue(store.connected, store.error ?? ""); XCTAssertFalse(page.closed)
    return Fixture(store: store, base: base, source: source, other: other, ready: ready, release: release, result: result, page: page)
  }
  func testCrossProjectSearchPreservesEmptyFullTargetAndColdRestoresItsLayout() async throws {
    let f = try await fixture(), store = f.store
    let opened = await store.openCommandBrowserTab(f.result)
    XCTAssertTrue(opened, store.error ?? "")
    XCTAssertEqual(store.project?.path, f.source.path); XCTAssertEqual(store.draft, "Source unsent input")
    XCTAssertEqual(store.focusedWorkspaceTabID, f.result.id); XCTAssertEqual(store.effectiveWorkspaceContentLayoutMode, .full)
    XCTAssertTrue(store.workspace.browser.selected === f.page); XCTAssertFalse(f.page.closed)
    XCTAssertEqual(store.library.drafts["new:\(f.other.path)"], "Other unsent input")
    await store.shutdown()
    let restored = WorkspaceStore(dataRoot: f.base.appendingPathComponent("Data"), agentExecutable: try AgentTestExecutable.url())
    addTeardownBlock { @MainActor in await restored.shutdown() }
    await restored.restore()
    XCTAssertEqual(restored.project?.path, f.source.path); XCTAssertEqual(restored.draft, "Source unsent input")
    XCTAssertEqual(restored.activeWorkspaceTabID, f.result.id); XCTAssertEqual(restored.effectiveWorkspaceContentLayoutMode, .full)
    XCTAssertFalse(try XCTUnwrap(restored.workspace.browser.selected).closed)
  }
  func testClosingSearchTargetDuringRealScopeInitializationDoesNotRecreateIt() async throws {
    let f = try await fixture(), store = f.store
    try FileManager.default.removeItem(at: f.ready); try FileManager.default.removeItem(at: f.release)
    let opening = Task { await store.openCommandBrowserTab(f.result) }
    for _ in 0..<200 where !FileManager.default.fileExists(atPath: f.ready.path) { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(FileManager.default.fileExists(atPath: f.ready.path))
    XCTAssertTrue(store.busy)
    store.closeBrowserTab(f.page.id)
    try Data().write(to: f.release)
    let opened = await opening.value
    XCTAssertFalse(opened); XCTAssertTrue(f.page.closed)
    XCTAssertFalse(store.workspaceTabs.contains { $0.id == f.result.id })
    XCTAssertNotEqual(store.focusedWorkspaceTabID, f.result.id)
    XCTAssertEqual(store.library.drafts["new:\(f.source.path)"], "Source unsent input")
    XCTAssertEqual(store.library.drafts["new:\(f.other.path)"], "Other unsent input")
  }
}
