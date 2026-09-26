import AppKit
import WebKit
import XCTest

@testable import ShipiOS

final class BrowserTests: XCTestCase {
  private var server: Process!
  private var base = ""
  override func setUpWithError() throws {
    server = Process()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/browser_server.py")
    server.arguments = ["-u", fixture.path]
    let pipe = Pipe(); server.standardOutput = pipe; server.standardError = FileHandle.nullDevice
    try server.run()
    let port = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard Int(port) != nil else { throw AgentFailure(message: "Fixture server failed") }
    base = "http://127.0.0.1:\(port)"
  }
  override func tearDown() {
    if server?.isRunning == true { server.terminate(); server.waitUntilExit() }
  }
  @MainActor private func eventually(_ message: String, _ condition: () -> Bool) async throws {
    for _ in 0..<320 {
      if condition() { return }
      try await Task.sleep(nanoseconds: 25_000_000)
    }
    throw AgentFailure(message: message)
  }
  @MainActor private func load(_ tab: BrowserTab, _ path: String, title: String) async throws {
    tab.address = base + path; tab.navigate()
    try await eventually("Page did not finish: \(path)") { !tab.loading && tab.title == title && tab.error == nil }
  }
  @MainActor func testPageEditableFocusReportsInputsAndClearsOnBlurAndNavigation() async throws {
    let session = BrowserSession()
    defer { session.shutdown() }
    let tab = session.newTab()
    try await load(tab, "/one", title: "One")
    XCTAssertFalse(tab.pageEditingText)
    _ = try await tab.view.evaluateJavaScript("document.getElementById('draft').focus()")
    try await eventually("Input focus did not reach the native page") { tab.pageEditingText }
    _ = try await tab.view.evaluateJavaScript("document.getElementById('draft').blur()")
    try await eventually("Input blur did not clear editing focus") { !tab.pageEditingText }
    _ = try await tab.view.evaluateJavaScript("""
      const editor = document.createElement('div');
      editor.contentEditable = 'true'; document.body.appendChild(editor); editor.focus();
      """)
    try await eventually("Contenteditable focus did not reach the native page") { tab.pageEditingText }
    try await load(tab, "/two", title: "Two")
    XCTAssertFalse(tab.pageEditingText)
  }
  @MainActor func testSharedWebKitControllerInstallsOneFocusMonitorAcrossTabs() async throws {
    let configuration = WKWebViewConfiguration()
    let first = BrowserTab(configuration: configuration)
    let scripts = configuration.userContentController.userScripts.count
    let second = BrowserTab(configuration: configuration)
    defer { first.close(); second.close() }
    XCTAssertEqual(configuration.userContentController.userScripts.count, scripts)
    first.close()
    try await load(second, "/one", title: "One")
    _ = try await second.view.evaluateJavaScript("document.getElementById('draft').focus()")
    try await eventually("Closing another tab removed shared focus monitoring") { second.pageEditingText }
  }
  @MainActor func testCopyURLTargetsExactVisiblePaneAndIgnoresClosedTab() async throws {
    let session = BrowserSession()
    defer { session.shutdown() }
    let first = session.newTab()
    try await load(first, "/one", title: "One")
    let second = session.newTab()
    try await load(second, "/two", title: "Two")
    let pasteboard = NSPasteboard(name: .init("window-tabs-copy-\(UUID())"))
    defer { pasteboard.releaseGlobally() }
    session.copyURL(tabID: first.id, to: pasteboard)
    XCTAssertEqual(pasteboard.string(forType: .string), base + "/one")
    XCTAssertEqual(session.selection, second.id)
    session.close(first.id)
    session.copyURL(tabID: first.id, to: pasteboard)
    XCTAssertEqual(pasteboard.string(forType: .string), base + "/one", "A closed pane must not copy a different page")
    session.copyURL(to: pasteboard)
    XCTAssertEqual(pasteboard.string(forType: .string), base + "/two")
  }

  @MainActor func testColdWorkspaceRestoreLoadsSavedPageWithoutSubmittingAddressDraft() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-cold-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let original = WorkspaceStore(dataRoot: root)
    original.libraryLoaded = true
    original.scopeLoaded = true
    original.library.tasks = [.init(id: "restored", project: "", title: "Restored", runIDs: [])]
    original.library.lastWorkspace = ""
    original.library.projectSelections[""] = "restored"
    original.selection = "restored"
    original.restoreWorkspaceTabLayout()
    original.newBrowserTab()
    let page = try XCTUnwrap(original.workspace.browser.selected)
    try await load(page, "/one", title: "One")
    page.address = "unfinished address edit"
    page.editingAddress = true
    let tabID = try XCTUnwrap(original.activeWorkspaceTabID)
    original.moveWorkspaceTab(tabID, to: .right)
    original.newBrowserTab()
    let empty = try XCTUnwrap(original.workspace.browser.selected)
    empty.address = "not a submitted URL"
    original.saveLibrary()
    await original.shutdown()

    let cold = WorkspaceStore(dataRoot: root)
    defer { cold.workspace.browser.shutdown() }
    await cold.restore()
    XCTAssertFalse(cold.restoringLibrary)
    XCTAssertNil(cold.libraryReadError)
    let restored = try XCTUnwrap(cold.workspace.browser.tabs.first { $0.id == page.id })
    try await eventually("Saved URL did not finish restoring") {
      restored.title == "One" && !restored.loading && restored.error == nil
    }
    XCTAssertEqual(restored.committedURL?.absoluteString, base + "/one")
    XCTAssertEqual(restored.address, "unfinished address edit")
    XCTAssertTrue(restored.editingAddress)
    XCTAssertEqual(cold.activeRightWorkspaceTabID, tabID)
    XCTAssertEqual(cold.activeWorkspaceContentTab?.browserID, empty.id)
    XCTAssertEqual(cold.workspace.browser.selected?.address, "not a submitted URL")
    XCTAssertNil(cold.workspace.browser.selected?.view.url)
    // A later save must keep the committed URL independently from both address drafts.
    cold.saveLibrary()
    let disk = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    let saved = try XCTUnwrap(disk.workspaceTabLayouts["restored"]?.tabs.first { $0.id == tabID })
    XCTAssertEqual(saved.committedURL, base + "/one")
    XCTAssertEqual(saved.address, "unfinished address edit")
  }

  func testAddressValidationAndLocalDevelopmentDefaults() throws {
    XCTAssertEqual(try BrowserAddress.url("localhost:3000/a").absoluteString, "http://localhost:3000/a")
    XCTAssertEqual(try BrowserAddress.url("[::1]:8080").scheme, "http")
    XCTAssertEqual(try BrowserAddress.url("example.com/docs").scheme, "https")
    XCTAssertEqual(try BrowserAddress.url("https://example.com").host, "example.com")
    for address in ["", "file:/tmp/file", "file:///tmp/file", "javascript:alert(1)", "data:text/html,hi", "about:blank",
      "ftp://example.com", "https://name:password@example.com", "localhost:0", "localhost:99999", "invalid host"] {
      XCTAssertThrowsError(try BrowserAddress.url(address), address)
    }
  }

  @MainActor func testMessageLinksReusePageAndMoveBetweenSplitAndFullWidth() async throws {
    let store = WorkspaceStore()
    defer { store.workspace.browser.shutdown() }
    store.library.tasks = [.init(id: "task", project: "", title: "Task", runIDs: ["run"])]
    store.selection = "run"
    store.draft = "keep draft"
    let url = try XCTUnwrap(URL(string: base + "/one"))
    await store.openWebLinkInApp(url, ownerRunID: "run")
    let tab = try XCTUnwrap(store.workspace.browser.selected)
    try await eventually("Message link did not load") { !tab.loading && tab.committedURL == url }
    XCTAssertNil(store.activeWorkspaceTabID)
    XCTAssertEqual(store.activeRightWorkspaceContentTab?.browserID, tab.id)
    XCTAssertEqual(store.workspace.browser.contentFocusTarget, tab.id)
    XCTAssertNil(store.workspace.browser.addressFocusTarget)
    try await tab.view.evaluateJavaScript("window.messageLinkState = 42")

    await store.openWebLinkInApp(url, ownerRunID: "run")
    XCTAssertEqual(store.workspace.browser.tabs.count, 1)
    let state = try await tab.view.evaluateJavaScript("window.messageLinkState") as? Int
    XCTAssertEqual(state, 42, "Reusing the exact URL must not reload the page")
    await store.openWebLinkInApp(url, ownerRunID: "run", presentation: .fullWidth)
    XCTAssertEqual(store.workspace.browser.tabs.count, 1)
    XCTAssertEqual(store.activeBrowserTabID, tab.id)
    XCTAssertFalse(store.showingInspector)
    await store.openWebLinkInApp(url, ownerRunID: "run", presentation: .split)
    XCTAssertNil(store.activeWorkspaceTabID)
    XCTAssertTrue(store.showingInspector)
    XCTAssertEqual(store.activeRightWorkspaceContentTab?.browserID, tab.id)
    XCTAssertEqual(store.draft, "keep draft")
  }

  @MainActor func testMessageNewTabGesturesPreserveBackgroundFocusButForegroundSelects() async throws {
    let store = WorkspaceStore()
    defer { store.workspace.browser.shutdown() }
    store.library.tasks = [.init(id: "task", project: "", title: "Task", runIDs: ["run"])]
    store.selection = "run"
    let url = try XCTUnwrap(URL(string: base + "/one"))
    await store.openWebLinkInApp(url, ownerRunID: "run")
    let first = try XCTUnwrap(store.activeRightWorkspaceTabID)
    store.activateChatTab()
    let focus = store.focusComposer
    let browserFocus = store.workspace.browser.contentFocus
    let selectedBrowser = store.workspace.browser.selection
    await store.openWebLinkInApp(url, ownerRunID: "run", presentation: .backgroundTab)
    XCTAssertEqual(store.workspace.browser.tabs.count, 2, "Modified click creates even when URL is already open")
    XCTAssertEqual(store.activeRightWorkspaceTabID, first)
    XCTAssertNil(store.focusedWorkspaceTabID)
    XCTAssertEqual(store.focusComposer, focus)
    XCTAssertEqual(store.workspace.browser.contentFocus, browserFocus)
    XCTAssertEqual(store.workspace.browser.selection, selectedBrowser)
    await store.openWebLinkInApp(url, ownerRunID: "run", presentation: .foregroundTab)
    XCTAssertEqual(store.workspace.browser.tabs.count, 3)
    XCTAssertNotEqual(store.activeRightWorkspaceTabID, first)
    XCTAssertEqual(store.focusedWorkspaceTabID, store.activeRightWorkspaceTabID)
    XCTAssertEqual(store.activeRightWorkspaceContentTab?.browserID, store.workspace.browser.selection)
  }

  @MainActor func testMessageLinkFragmentReusesDocumentButQueryCreatesAnotherTab() async throws {
    let store = WorkspaceStore()
    defer { store.workspace.browser.shutdown() }
    let url = try XCTUnwrap(URL(string: base + "/one"))
    await store.openWebLinkInApp(url, ownerRunID: nil)
    let tab = try XCTUnwrap(store.workspace.browser.selected)
    try await eventually("Initial document did not load") { !tab.loading && tab.committedURL == url }
    try await tab.view.evaluateJavaScript("window.linkDocumentMarker = 73")
    let fragment = try XCTUnwrap(URL(string: base + "/one#section"))
    await store.openWebLinkInApp(fragment, ownerRunID: nil)
    try await eventually("Fragment did not update") { !tab.loading && tab.committedURL == fragment }
    XCTAssertEqual(store.workspace.browser.tabs.count, 1)
    let marker = try await tab.view.evaluateJavaScript("window.linkDocumentMarker") as? Int
    XCTAssertEqual(marker, 73, "Following an anchor must preserve the document")
    await store.openWebLinkInApp(URL(string: base + "/one?different=true")!, ownerRunID: nil)
    XCTAssertEqual(store.workspace.browser.tabs.count, 2, "A distinct query is a distinct page")
  }

  @MainActor func testRepeatedMessageLinkDuringInitialLoadKeepsSingleTab() async throws {
    let store = WorkspaceStore()
    defer { store.workspace.browser.shutdown() }
    let url = try XCTUnwrap(URL(string: base + "/slow"))
    await store.openWebLinkInApp(url, ownerRunID: nil)
    let tab = try XCTUnwrap(store.workspace.browser.selected)
    XCTAssertTrue(tab.loading)
    await store.openWebLinkInApp(url, ownerRunID: nil)
    XCTAssertEqual(store.workspace.browser.tabs.count, 1)
    XCTAssertEqual(store.workspace.browser.selected?.id, tab.id)
    try await eventually("Pending message link did not load") { !tab.loading && tab.committedURL == url }
  }

  @MainActor func testFirstBackgroundMessageTabRevealsWithoutFocusAndOtherOwnerStaysHidden() async throws {
    let store = WorkspaceStore()
    defer { store.workspace.browser.shutdown() }
    store.library.tasks = [
      .init(id: "first", project: "", title: "First", runIDs: ["run1"]),
      .init(id: "second", project: "/another-project", title: "Second", runIDs: ["run2"]),
    ]
    store.selection = "run1"
    let focus = store.focusComposer
    let url = try XCTUnwrap(URL(string: base + "/one"))
    await store.openWebLinkInApp(url, ownerRunID: "run2", presentation: .backgroundTab)
    XCTAssertEqual(store.selectedTask?.id, "first")
    XCTAssertEqual(store.currentProjectKey, "")
    XCTAssertTrue(store.visibleWorkspaceContentTabs.isEmpty)
    XCTAssertEqual(store.workspaceTabs.first?.owner, "second")
    XCTAssertFalse(store.showingInspector)
    await store.openWebLinkInApp(url, ownerRunID: "run1", presentation: .backgroundTab)
    XCTAssertTrue(store.showingInspector)
    XCTAssertEqual(store.activeRightWorkspaceContentTab?.owner, "first")
    XCTAssertNil(store.focusedWorkspaceTabID)
    XCTAssertNil(store.workspace.browser.selection)
    XCTAssertEqual(store.focusComposer, focus)
    await store.openWebLinkInApp(url, ownerRunID: "missing", presentation: .backgroundTab)
    XCTAssertEqual(store.workspace.browser.tabs.count, 2)
    XCTAssertEqual(store.error, "链接所属的任务已不可用。")
  }
  func testBrowserPermissionNormalizationResolutionAndLegacyMigration() throws {
    XCTAssertEqual(try BrowserPermissionPreferences.normalizedHost("Example.COM."), "example.com")
    XCTAssertEqual(
      try BrowserPermissionPreferences.normalizedHost("https://Docs.Example.com/path?q=1"),
      "docs.example.com")
    for value in ["", "file:///tmp/a", "https://name:password@example.com", "invalid host"] {
      XCTAssertThrowsError(try BrowserPermissionPreferences.normalizedHost(value), value)
    }
    var preferences = BrowserPermissionPreferences()
    preferences.defaultDecision = .ask
    preferences.sites["example.com"] = .block
    XCTAssertEqual(preferences.decision(for: URL(string: "https://example.com/a")!), .block)
    XCTAssertEqual(preferences.decision(for: URL(string: "https://other.example/a")!), .ask)

    let legacy = try JSONDecoder().decode(WorkspaceLibrary.self, from: Data("{}".utf8))
    XCTAssertEqual(legacy.browserPermissions, BrowserPermissionPreferences())
    XCTAssertEqual(legacy.browserDownloadPreferences, BrowserDownloadPreferences())
    XCTAssertTrue(legacy.browserDownloads.isEmpty)
  }
  @MainActor func testDownloadFolderPersistsAndAutomaticNamesNeverOverwrite() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let downloads = root.appendingPathComponent("downloads", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    XCTAssertTrue(store.setBrowserDownloadFolder(downloads))
    store.setBrowserAskWhereToSave(true)
    store.setBrowserAskWhereToSave(false)
    let first = try store.automaticBrowserDownloadDestination(filename: "../fixture.txt")
    XCTAssertEqual(first.lastPathComponent, "..-fixture.txt")
    try Data("existing".utf8).write(to: first)
    let second = try store.automaticBrowserDownloadDestination(filename: "../fixture.txt")
    XCTAssertEqual(second.lastPathComponent, "..-fixture 2.txt")
    let restored = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    XCTAssertEqual(restored.browserDownloadPreferences.directory, downloads.path)
    XCTAssertFalse(restored.browserDownloadPreferences.askWhereToSave)
  }
  @MainActor func testRealWebKitDownloadPersistsRecordAndExactFile() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let downloads = root.appendingPathComponent("downloads", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    defer { store.workspace.browser.shutdown() }
    XCTAssertTrue(store.setBrowserDownloadFolder(downloads))
    store.newBrowserTab()
    let tab = try XCTUnwrap(store.workspace.browser.selected)
    try await load(tab, "/one", title: "One")

    _ = try await tab.view.evaluateJavaScript("document.getElementById('download').click(); undefined")
    try await eventually("Download did not finish") {
      store.browserDownloads.first?.status == .finished
    }
    XCTAssertNil(tab.error)
    let record = try XCTUnwrap(store.browserDownloads.first)
    XCTAssertEqual(record.filename, "fixture.txt")
    XCTAssertEqual(record.sourceURL, base + "/download")
    XCTAssertEqual(record.destinationPath, downloads.appendingPathComponent("fixture.txt").path)
    XCTAssertEqual(record.byteCount, 25)
    XCTAssertEqual(store.browserDownloadProgress[record.id], 1)
    XCTAssertEqual(
      try String(contentsOf: downloads.appendingPathComponent("fixture.txt"), encoding: .utf8),
      "shipios browser download\n")
    let persisted = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    XCTAssertEqual(persisted.browserDownloads.first, record)

    _ = try await tab.view.evaluateJavaScript("document.getElementById('download').click(); undefined")
    try await eventually("Second download did not finish") {
      store.browserDownloads.count == 2 && store.browserDownloads.allSatisfy { $0.status == .finished }
    }
    let second = try XCTUnwrap(store.browserDownloads.first)
    XCTAssertEqual(second.filename, "fixture 2.txt")
    XCTAssertEqual(second.destinationPath, downloads.appendingPathComponent("fixture 2.txt").path)
    XCTAssertEqual(
      try String(contentsOf: downloads.appendingPathComponent("fixture 2.txt"), encoding: .utf8),
      "shipios browser download\n")

    store.clearFinishedBrowserDownloads()
    XCTAssertTrue(store.browserDownloads.isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: downloads.appendingPathComponent("fixture.txt").path))
  }

  @MainActor func testOptionMessageDownloadUsesExistingHistoryWithoutTabOrFocusChanges() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    defer { store.workspace.browser.shutdown() }
    XCTAssertTrue(store.setBrowserDownloadFolder(root))
    store.library.tasks = [.init(id: "task", project: "", title: "Task", runIDs: ["run"])]
    store.selection = "run"
    store.draft = "unsent draft"
    store.library.webLinkTarget = .externalBrowser
    let focus = store.focusComposer
    let addressFocus = store.workspace.browser.addressFocus
    let url = try XCTUnwrap(URL(string: base + "/download"))
    var openedExternal = false
    store.openMessageLink(url, project: nil, ownerRunID: "run", click: .init(modifiers: .option)) {
      _ in openedExternal = true; return true
    }
    let firstID = try XCTUnwrap(store.browserDownloads.first?.id)
    XCTAssertEqual(store.browserDownloads.first?.status, .preparing)
    try await eventually("Message download did not finish") { store.browserDownloads.first?.status == .finished }
    XCTAssertEqual(store.browserDownloads.first?.id, firstID)
    XCTAssertEqual(store.browserDownloads.count, 1)
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("fixture.txt")), "shipios browser download\n")
    XCTAssertFalse(openedExternal)
    XCTAssertTrue(store.workspace.browser.tabs.isEmpty)
    XCTAssertTrue(store.workspaceTabs.isEmpty)
    XCTAssertEqual(store.selectedTask?.id, "task")
    XCTAssertEqual(store.draft, "unsent draft")
    XCTAssertEqual(store.focusComposer, focus)
    XCTAssertEqual(store.workspace.browser.addressFocus, addressFocus)
    XCTAssertTrue(store.messageDownloadIDs.isEmpty)
    let persisted = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    XCTAssertEqual(persisted.browserDownloads.first?.status, .finished)

    _ = store.downloadMessageLink(url)
    try await eventually("Second message download did not finish") {
      store.browserDownloads.count == 2 && store.browserDownloads.allSatisfy { $0.status == .finished }
    }
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("fixture 2.txt")), "shipios browser download\n")
    try store.shortcuts.setExternalBrowserLinkShortcut(.alt)
    store.openMessageLink(url, project: nil, click: .init(modifiers: .option)) { _ in openedExternal = true; return true }
    XCTAssertTrue(openedExternal)
    XCTAssertEqual(store.browserDownloads.count, 2, "Configured Option external-browser shortcut overrides download")
  }

  @MainActor func testMessageDownloadCanSaveOrdinaryHTMLAndDeclineDestination() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    defer { store.workspace.browser.shutdown() }
    let saved = root.appendingPathComponent("page.html")
    store.workspace.browser.chooseDownloadDestination = { _, _, completion in completion(.save(saved)) }
    let id = try XCTUnwrap(store.downloadMessageLink(URL(string: base + "/one")!))
    try await eventually("Ordinary webpage did not download") {
      store.browserDownloads.first(where: { $0.id == id })?.status == .finished
    }
    XCTAssertTrue(try String(contentsOf: saved).contains("Fixture page"))
    store.workspace.browser.chooseDownloadDestination = { _, _, completion in completion(.cancel) }
    let declined = try XCTUnwrap(store.downloadMessageLink(URL(string: base + "/download")!))
    try await eventually("Declined destination did not cancel") {
      store.browserDownloads.first(where: { $0.id == declined })?.status == .cancelled
    }
    XCTAssertTrue(store.notices.items.isEmpty, "Cancelling a save picker is not a download failure")
    XCTAssertTrue(store.messageDownloadIDs.isEmpty)
  }

  @MainActor func testMessageDownloadImmediateCancellationCannotRestartAndShutdownCancelsPending() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    XCTAssertTrue(store.setBrowserDownloadFolder(root))
    let first = try XCTUnwrap(store.downloadMessageLink(URL(string: base + "/download-slow")!))
    store.cancelBrowserDownload(first)
    XCTAssertEqual(store.browserDownloads.first?.status, .cancelled)
    let second = try XCTUnwrap(store.downloadMessageLink(URL(string: base + "/slow")!))
    store.workspace.browser.shutdown()
    XCTAssertEqual(store.browserDownloads.first(where: { $0.id == second })?.status, .cancelled)
    try await Task.sleep(for: .milliseconds(250))
    XCTAssertTrue(store.browserDownloads.allSatisfy { $0.status == .cancelled })
    XCTAssertTrue(store.messageDownloadIDs.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("slow.bin").path))
  }

  @MainActor func testMessageDownloadNetworkFailureProducesRecordAndNotice() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    defer { store.workspace.browser.shutdown() }
    let id = try XCTUnwrap(store.downloadMessageLink(URL(string: base + "/disconnect")!))
    try await eventually("Broken connection did not fail") {
      store.browserDownloads.first(where: { $0.id == id })?.status == .failed
    }
    XCTAssertNotNil(store.browserDownloads.first?.message)
    XCTAssertTrue(store.notices.items.contains { $0.id == "message-link-download:\(id)" && $0.level == .error })
    XCTAssertTrue(store.messageDownloadIDs.isEmpty)
    let count = store.browserDownloads.count
    XCTAssertNil(store.downloadMessageLink(URL(string: "file:///tmp/no-download")!))
    XCTAssertEqual(store.browserDownloads.count, count)
  }

  @MainActor func testMessageDownloadInvalidDestinationIsFailureRatherThanCancellation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let invalid = root.appendingPathComponent("not-a-directory")
    try Data("do not overwrite".utf8).write(to: invalid)
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    defer { store.workspace.browser.shutdown() }
    store.library.browserDownloadPreferences.directory = invalid.path
    let id = try XCTUnwrap(store.downloadMessageLink(URL(string: base + "/download")!))
    try await eventually("Invalid folder did not report failure") {
      store.browserDownloads.first(where: { $0.id == id })?.status == .failed
    }
    XCTAssertNotNil(store.browserDownloads.first?.message)
    XCTAssertTrue(store.notices.items.contains { $0.level == .error })
    XCTAssertEqual(try String(contentsOf: invalid), "do not overwrite")
  }

  @MainActor func testLateSaveDestinationCannotReviveCancelledMessageDownload() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    defer { store.workspace.browser.shutdown() }
    var finishChoosing: ((BrowserDownloadDestination) -> Void)?
    store.workspace.browser.chooseDownloadDestination = { _, _, completion in finishChoosing = completion }
    let id = try XCTUnwrap(store.downloadMessageLink(URL(string: base + "/download")!))
    try await eventually("Destination picker was not requested") { finishChoosing != nil }
    store.cancelBrowserDownload(id)
    finishChoosing?(.save(root.appendingPathComponent("late.txt")))
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(store.browserDownloads.first?.status, .cancelled)
    XCTAssertNil(store.browserDownloads.first?.destinationPath)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("late.txt").path))
  }

  @MainActor func testPerLinkDestinationOverrideDoesNotChangeDefaultDownloadBehavior() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    defer { store.workspace.browser.shutdown() }
    var defaultChoices = 0
    var explicitChoices = 0
    store.workspace.browser.chooseDownloadDestination = { _, _, completion in
      defaultChoices += 1
      completion(.save(root.appendingPathComponent("default.txt")))
    }
    let url = URL(string: base + "/download")!
    let explicit = try XCTUnwrap(store.workspace.browser.downloadLink(url, chooseDestination: { _, _, completion in
      explicitChoices += 1
      completion(.save(root.appendingPathComponent("explicit.txt")))
    }))
    let normal = try XCTUnwrap(store.workspace.browser.downloadLink(url))
    try await eventually("Both destination choices did not finish") {
      store.browserDownloads.filter { $0.id == explicit || $0.id == normal }.count == 2
        && store.browserDownloads.allSatisfy { $0.status == .finished }
    }
    XCTAssertEqual(defaultChoices, 1)
    XCTAssertEqual(explicitChoices, 1)
    XCTAssertFalse(store.library.browserDownloadPreferences.askWhereToSave)
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("explicit.txt")), "shipios browser download\n")
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("default.txt")), "shipios browser download\n")
  }

  @MainActor func testExplicitMessageMenuOpenUsesInAppEvenWhenPreferenceIsExternal() async throws {
    let store = WorkspaceStore()
    defer { store.workspace.browser.shutdown() }
    store.library.webLinkTarget = .externalBrowser
    let url = URL(string: base + "/one")!
    store.performMessageLinkAction(.openInApp, url: url, ownerRunID: nil)
    try await eventually("Explicit menu did not open browser") {
      store.workspace.browser.selected?.committedURL == url
    }
    XCTAssertNotNil(store.activeRightWorkspaceContentTab?.browserID)
    XCTAssertTrue(store.showingInspector)
    XCTAssertEqual(store.library.webLinkTarget, .externalBrowser)
  }
  @MainActor func testActiveWebKitDownloadCanBeCancelled() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let downloads = root.appendingPathComponent("downloads", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    defer { store.workspace.browser.shutdown() }
    XCTAssertTrue(store.setBrowserDownloadFolder(downloads))
    store.newBrowserTab()
    let tab = try XCTUnwrap(store.workspace.browser.selected)
    try await load(tab, "/one", title: "One")

    _ = try await tab.view.evaluateJavaScript(
      "document.getElementById('download-slow').click(); undefined")
    try await eventually("Slow download did not start") {
      store.browserDownloads.first?.status == .downloading
    }
    let id = try XCTUnwrap(store.browserDownloads.first?.id)
    store.cancelBrowserDownload(id)
    try await eventually("Slow download did not cancel") {
      store.browserDownloads.first?.status == .cancelled
    }
    XCTAssertNil(store.browserDownloadProgress[id])
    XCTAssertNil(tab.error)
  }
  @MainActor func testBrowserPermissionRulesPersistAndCanReturnToDefault() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    XCTAssertTrue(store.setBrowserSiteAccess("https://Allowed.Example/path", decision: .allow))
    store.setBrowserDefaultAccess(.block)
    XCTAssertEqual(store.browserPermissionPreferences.sites, ["allowed.example": .allow])
    XCTAssertEqual(store.browserPermissionPreferences.defaultDecision, .block)
    let restored = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    XCTAssertEqual(restored.browserPermissions, store.browserPermissionPreferences)
    XCTAssertTrue(store.setBrowserSiteAccess("allowed.example", decision: .ask))
    XCTAssertTrue(store.browserPermissionPreferences.sites.isEmpty)
  }
  @MainActor func testTabSelectionClosingAndSettingsPreserveOwnership() {
    let store = WorkspaceStore()
    defer { store.workspace.browser.shutdown() }
    store.executeCommand("browser-new")
    let first = store.workspace.browser.selected!
    first.address = "unsent first address"
    store.executeCommand("browser-new")
    let second = store.workspace.browser.selected!
    XCTAssertNotEqual(first.id, second.id)
    store.workspace.browser.move(-1)
    XCTAssertTrue(store.workspace.browser.selected === first)
    store.openSettings(.general)
    XCTAssertFalse(store.browserVisible)
    XCTAssertFalse(store.commandEnabled("browser-reload"))
    store.closeSettings()
    XCTAssertTrue(store.browserVisible)
    XCTAssertEqual(store.workspace.browser.selected?.address, "unsent first address")
    store.closeBrowserTab(second.id)
    XCTAssertTrue(second.closed)
    XCTAssertTrue(store.workspace.browser.selected === first)
    store.closeBrowserTab(first.id)
    XCTAssertFalse(store.showingInspector)
    XCTAssertTrue(store.workspace.browser.tabs.isEmpty)
    XCTAssertTrue(store.commandEnabled("browser-reopen"))
    store.executeCommand("browser-reopen")
    XCTAssertTrue(store.browserVisible)
    XCTAssertEqual(store.workspace.browser.tabs.count, 1)
    XCTAssertEqual(store.workspace.browser.selected?.address, "unsent first address")
    XCTAssertTrue(store.commandEnabled("browser-reopen"))
    store.executeCommand("browser-reopen")
    XCTAssertEqual(store.workspace.browser.tabs.count, 2)
    XCTAssertEqual(store.workspace.browser.selected?.address, "")
    XCTAssertFalse(store.commandEnabled("browser-reopen"))
  }
  @MainActor func testTabDragOrderingAndBatchCloseKeepExactOwnership() {
    let session = BrowserSession()
    defer { session.shutdown() }
    let first = session.newTab()
    let second = session.newTab()
    let third = session.newTab()
    let fourth = session.newTab()
    session.select(second.id)
    session.addressFocusTarget = second.id

    XCTAssertFalse(session.reorderTab(first.id, horizontalTranslation: 10, sourceWidth: 46))
    XCTAssertTrue(session.reorderTab(first.id, horizontalTranslation: 50, sourceWidth: 46))
    XCTAssertEqual(session.tabs.map(\.id), [second.id, first.id, third.id, fourth.id])
    XCTAssertTrue(session.reorderTab(first.id, horizontalTranslation: -50, sourceWidth: 46))
    XCTAssertEqual(session.tabs.map(\.id), [first.id, second.id, third.id, fourth.id])
    XCTAssertTrue(session.reorderTab(first.id, relativeTo: fourth.id, after: true))
    XCTAssertEqual(session.tabs.map(\.id), [second.id, third.id, fourth.id, first.id])
    XCTAssertEqual(session.selection, second.id)
    XCTAssertEqual(session.addressFocusTarget, second.id)
    XCTAssertFalse(session.reorderTab(first.id, relativeTo: first.id, after: false))

    XCTAssertTrue(session.canCloseTabsToRight(of: third.id))
    session.closeTabsToRight(of: third.id)
    XCTAssertEqual(session.tabs.map(\.id), [second.id, third.id])
    XCTAssertEqual(session.selection, third.id)
    XCTAssertTrue(fourth.closed)
    XCTAssertTrue(first.closed)
    XCTAssertFalse(session.canCloseTabsToRight(of: third.id))

    session.closeOtherTabs(keeping: second.id)
    XCTAssertEqual(session.tabs.map(\.id), [second.id])
    XCTAssertEqual(session.selection, second.id)
    XCTAssertTrue(third.closed)
    XCTAssertFalse(second.closed)
  }
  @MainActor func testRealNavigationHistoryRedirectAndReloadFromOrigin() async throws {
    _ = NSApplication.shared
    let session = BrowserSession()
    defer { session.shutdown() }
    let tab = session.newTab()
    try await load(tab, "/one", title: "One")
    XCTAssertFalse(tab.canGoBack)
    try await load(tab, "/redirect", title: "Two")
    XCTAssertEqual(tab.committedURL?.path, "/two")
    XCTAssertTrue(tab.canGoBack)
    tab.back()
    try await eventually("Back did not restore first page") { tab.title == "One" && !tab.loading }
    XCTAssertTrue(tab.canGoForward)
    tab.forward()
    try await eventually("Forward did not restore second page") { tab.title == "Two" && !tab.loading }
    try await load(tab, "/cache", title: "Cache 1")
    tab.reload(bypassCache: true)
    try await eventually("Reload used stale cached content") { tab.title == "Cache 2" && !tab.loading }
  }
  @MainActor func testPageInitiatedLastCloseDoesNotLeaveEmptyPaneOrStealSettingsFocus() {
    let store = WorkspaceStore()
    defer { store.workspace.browser.shutdown() }
    store.newBrowserTab()
    let tab = store.workspace.browser.selected!
    store.openSettings(.model)
    let focus = store.focusComposer
    tab.webViewDidClose(tab.view)
    XCTAssertTrue(store.workspace.browser.tabs.isEmpty)
    XCTAssertFalse(store.showingInspector)
    XCTAssertEqual(store.destination, .settings)
    XCTAssertEqual(store.settingsPage, .model)
    XCTAssertEqual(store.focusComposer, focus)
    store.closeSettings()
    XCTAssertFalse(store.showingInspector)
  }
  @MainActor func testTabsRetainIndependentPageStateAndAddressDraft() async throws {
    let session = BrowserSession()
    defer { session.shutdown() }
    let first = session.newTab()
    try await load(first, "/one", title: "One")
    _ = try await first.view.evaluateJavaScript("document.getElementById('draft').value='changed'")
    let second = session.newTab()
    try await load(second, "/two", title: "Two")
    session.select(first.id)
    let retainedValue = try await first.view.evaluateJavaScript("document.getElementById('draft').value") as? String
    XCTAssertEqual(retainedValue, "changed")
    first.editingAddress = true; first.address = "typing another destination"
    _ = try await first.view.evaluateJavaScript("history.pushState({}, '', '/one?updated=1')")
    try await eventually("Same-document URL did not update") { first.committedURL?.query == "updated=1" }
    XCTAssertEqual(first.address, "typing another destination")
    first.restoreAddress()
    XCTAssertEqual(first.address, base + "/one?updated=1")
    XCTAssertEqual(second.committedURL?.path, "/two")
  }
  @MainActor func testCancelledNavigationDoesNotReplaceNewPageWithError() async throws {
    let session = BrowserSession()
    defer { session.shutdown() }
    let tab = session.newTab()
    tab.address = base + "/slow"; tab.navigate()
    try await Task.sleep(nanoseconds: 100_000_000)
    tab.stop()
    try await load(tab, "/two", title: "Two")
    try await Task.sleep(nanoseconds: 650_000_000)
    XCTAssertNil(tab.error)
    XCTAssertEqual(tab.title, "Two")
    tab.address = "file:///tmp/file"; tab.navigate()
    XCTAssertNotNil(tab.error)
    XCTAssertEqual(tab.committedURL?.path, "/two")
    try await load(tab, "/one", title: "One")
    XCTAssertNil(tab.error)
  }
  @MainActor func testPageNewWindowUsesOwnedTabAndClosesIt() async throws {
    let session = BrowserSession()
    defer { session.shutdown() }
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
    let source = session.newTab(configuration: configuration)
    try await load(source, "/one", title: "One")
    _ = try await source.view.evaluateJavaScript("window.open('/popup', '_blank'); undefined")
    try await eventually("Popup not owned by tab collection") { session.tabs.count == 2 && session.selected?.title == "Popup" }
    let popup = try XCTUnwrap(session.selected)
    XCTAssertFalse(popup === source)
    _ = try await popup.view.evaluateJavaScript("window.close(); undefined")
    try await eventually("Page close did not close its tab") { session.tabs.count == 1 }
    XCTAssertTrue(popup.closed)
    XCTAssertTrue(session.selected === source)
  }
  @MainActor func testDetachedWebKitPopupKeepsSourceTaskWhileMainDisplaysAnotherPage() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("popup-owner-\(UUID())")
    let store = WorkspaceStore(dataRoot: root)
    defer { store.workspace.browser.shutdown(); try? FileManager.default.removeItem(at: root) }
    store.libraryLoaded = true; store.scopeLoaded = true
    store.library.tasks = [.init(id: "a", project: "", title: "A", runIDs: []),
      .init(id: "b", project: "", title: "B", runIDs: [])]
    store.selection = "a"; store.restoreWorkspaceTabLayout()
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.preferences.javaScriptCanOpenWindowsAutomatically = true
    let source = store.workspace.browser.newTab(configuration: config)
    store.workspaceTabPlacements["browser:\(source.id)"] = .detached
    try await load(source, "/one", title: "One")
    store.applyTaskSelection(store.library.tasks[1]); store.newBrowserTab()
    let main = try XCTUnwrap(store.workspace.browser.selected)
    try await load(main, "/two", title: "Two")
    let layout = store.workspaceTabLayoutSnapshot, focus = store.focusComposer
    _ = try await source.view.evaluateJavaScript("window.open('/popup', '_blank'); undefined")
    try await eventually("Source popup was not loaded") { store.workspace.browser.tabs.contains { $0.title == "Popup" } }
    let popup = try XCTUnwrap(store.workspace.browser.tabs.first { $0.title == "Popup" })
    let id = "browser:\(popup.id)"
    XCTAssertEqual(store.workspaceTabs.first { $0.id == id }?.owner, "a")
    XCTAssertEqual(store.workspaceTabPlacement(id), .detached)
    XCTAssertEqual(store.takePendingDetachedWindowRoutes().map(\.tabID), [id])
    XCTAssertEqual(store.selection, "b"); XCTAssertEqual(store.workspace.browser.selection, main.id)
    XCTAssertEqual(store.workspaceTabLayoutSnapshot, layout); XCTAssertEqual(store.focusComposer, focus)
    popup.address = "unfinished popup address"
    store.saveLibrary()
    let disk = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    let saved = try XCTUnwrap(disk.workspaceTabLayouts["a"]?.tabs.first { $0.id == id })
    XCTAssertEqual(saved.committedURL, base + "/popup")
    XCTAssertEqual(saved.address, "unfinished popup address")
    _ = try await popup.view.evaluateJavaScript("window.close(); undefined")
    try await eventually("Popup close did not remove owned tab") { popup.closed }
    XCTAssertFalse(store.library.workspaceTabLayouts["a"]?.tabs.contains { $0.id == id } == true)
    XCTAssertFalse(main.closed); XCTAssertFalse(source.closed)
    XCTAssertEqual(store.workspace.browser.selection, main.id)
    XCTAssertEqual(store.focusComposer, focus)
  }
  @MainActor func testCopyUsesCurrentPageURLAndPrivatePasteboard() async throws {
    let store = WorkspaceStore()
    defer { store.workspace.browser.shutdown() }
    store.newBrowserTab()
    let tab = try XCTUnwrap(store.workspace.browser.selected)
    try await load(tab, "/redirect", title: "Two")
    tab.editingAddress = true; tab.address = "unsent edit"
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    store.copyBrowserURL(to: board)
    XCTAssertEqual(board.string(forType: .string), base + "/two")
    store.executeCommand("browser")
    XCTAssertFalse(store.showingInspector)
    XCTAssertFalse(store.browserFocused)
    store.executeCommand("browser")
    XCTAssertTrue(store.workspace.browser.selected === tab)
  }
  @MainActor func testElementPickerCapturesReferenceAndCanBeCancelled() async throws {
    let session = BrowserSession()
    defer { session.shutdown() }
    let tab = session.newTab()
    try await load(tab, "/one", title: "One")

    let selection = Task { @MainActor in await tab.selectElement() }
    try await eventually("Element picker did not start") { tab.selectingElement }
    _ = try await tab.view.evaluateJavaScript(
      "document.getElementById('next').dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true })); undefined")
    let selectedReference = await selection.value
    let reference = try XCTUnwrap(selectedReference)
    XCTAssertEqual(reference.url, base + "/one")
    XCTAssertEqual(reference.pageTitle, "One")
    XCTAssertEqual(reference.selector, "#next")
    XCTAssertEqual(reference.tag, "a")
    XCTAssertEqual(reference.text, "Next")
    XCTAssertEqual(reference.selectionKind, "element")
    XCTAssertNotNil(reference.rect)
    XCTAssertEqual(tab.selectedElement, reference)
    XCTAssertEqual(tab.committedURL?.path, "/one")

    tab.clearSelectedElement()
    let cancellation = Task { @MainActor in await tab.selectElement() }
    try await eventually("Second element picker did not start") { tab.selectingElement }
    tab.cancelElementSelection()
    let cancelledReference = await cancellation.value
    XCTAssertNil(cancelledReference)
    XCTAssertFalse(tab.selectingElement)
    XCTAssertNil(tab.elementSelectionError)
  }
  @MainActor func testContextMenuResolvesClickedLinkAndMatchesCodexActions() async throws {
    _ = NSApplication.shared
    let session = BrowserSession()
    defer { session.shutdown() }
    let tab = session.newTab()
    tab.view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
    try await load(tab, "/one", title: "One")
    let rectValue = try await tab.view.evaluateJavaScript(
      """
      (() => { const r = document.getElementById('next').getBoundingClientRect();
        return { x: r.left, y: r.top, width: r.width, height: r.height }; })()
      """)
    let rect = try XCTUnwrap(rectValue as? [String: Any])
    let left = try XCTUnwrap((rect["x"] as? NSNumber)?.doubleValue)
    let width = try XCTUnwrap((rect["width"] as? NSNumber)?.doubleValue)
    let rectTop = try XCTUnwrap((rect["y"] as? NSNumber)?.doubleValue)
    let height = try XCTUnwrap((rect["height"] as? NSNumber)?.doubleValue)
    XCTAssertTrue(tab.view.isFlipped)
    let resolvedTarget = await tab.contextTarget(
      at: NSPoint(x: left + width / 2, y: rectTop + height / 2))
    let target = try XCTUnwrap(resolvedTarget)

    XCTAssertEqual(target.pageURL.absoluteString, base + "/one")
    XCTAssertEqual(target.linkURL?.absoluteString, base + "/two")
    XCTAssertEqual(target.reference.selector, "#next")
    XCTAssertEqual(target.reference.text, "Next")
    let menu = tab.makeContextMenu(for: target)
    XCTAssertEqual(menu.items.map(\.title).filter { !$0.isEmpty }, [
      "复制链接地址", "后退", "前进", "重新加载", "在外部浏览器中打开",
      "在新标签页中打开链接", "检查", "使用 Codex 评论",
    ])
    XCTAssertEqual(menu.item(withTitle: "后退")?.isEnabled, false)
    XCTAssertEqual(menu.item(withTitle: "前进")?.isEnabled, false)

    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    tab.copyContextLink(to: board)
    XCTAssertEqual(board.string(forType: .string), base + "/two")

    let commentItem = try XCTUnwrap(menu.item(withTitle: "使用 Codex 评论"))
    XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(commentItem.action),
      to: commentItem.target, from: commentItem))
    XCTAssertEqual(tab.selectedElement, target.reference)

    let headingRectValue = try await tab.view.evaluateJavaScript(
      """
      (() => { const r = document.querySelector('h1').getBoundingClientRect();
        return { x: r.left, y: r.top, width: r.width, height: r.height }; })()
      """)
    let headingRect = try XCTUnwrap(headingRectValue as? [String: Any])
    let headingTarget = await tab.contextTarget(at: NSPoint(
      x: try XCTUnwrap((headingRect["x"] as? NSNumber)?.doubleValue) + 4,
      y: try XCTUnwrap((headingRect["y"] as? NSNumber)?.doubleValue) + 4))
    let pageMenu = tab.makeContextMenu(for: try XCTUnwrap(headingTarget))
    XCTAssertNil(pageMenu.item(withTitle: "复制链接地址"))
    XCTAssertNil(pageMenu.item(withTitle: "在新标签页中打开链接"))
    XCTAssertNotNil(pageMenu.item(withTitle: "在外部浏览器中打开"))

    _ = tab.makeContextMenu(for: target)
    let newTabItem = try XCTUnwrap(menu.item(withTitle: "在新标签页中打开链接"))
    XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(newTabItem.action),
      to: newTabItem.target, from: newTabItem))
    try await eventually("Context link did not open in an owned tab") {
      session.tabs.count == 2 && session.selected?.title == "Two"
    }
    XCTAssertEqual(session.selected?.committedURL?.absoluteString, base + "/two")
    session.close(tab.id)
    XCTAssertNil(tab.contextTarget)
    XCTAssertNil(tab.nativeInspectTarget)
    XCTAssertNil(tab.nativeInspectAction)
  }
  @MainActor func testElementPickerCapturesDraggedRegionAndRendersNumberedMarkers() async throws {
    let session = BrowserSession()
    defer { session.shutdown() }
    let tab = session.newTab()
    tab.view.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
    try await load(tab, "/one", title: "One")

    let selection = Task { @MainActor in await tab.selectElement() }
    try await eventually("Region picker did not start") { tab.selectingElement }
    _ = try await tab.view.evaluateJavaScript(
      """
      const target = document.getElementById('draft');
      target.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true, button: 0, clientX: 30, clientY: 40 }));
      target.dispatchEvent(new MouseEvent('mousemove', { bubbles: true, cancelable: true, button: 0, clientX: 150, clientY: 100 }));
      target.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, cancelable: true, button: 0, clientX: 150, clientY: 100 }));
      undefined
      """)
    let selectedReference = await selection.value
    let reference = try XCTUnwrap(selectedReference)
    XCTAssertEqual(reference.selectionKind, "region")
    XCTAssertEqual(reference.rect?.width, 120)
    XCTAssertEqual(reference.rect?.height, 60)
    let comments = [
      BrowserComment(reference: reference, body: "Make this region narrower"),
      BrowserComment(reference: reference, body: "Keep the input aligned"),
    ]
    await tab.renderCommentMarkers(comments)
    let markerCount = try await tab.view.evaluateJavaScript(
      "document.querySelectorAll('[data-shipios-comments] span').length") as? Int
    XCTAssertEqual(markerCount, 2)
  }
  @MainActor func testBrowserCommentsPersistStayTaskScopedAndQueueWithNextMessage() async throws {
    let store = WorkspaceStore()
    store.project = URL(fileURLWithPath: "/app")
    store.connected = true
    let run = AgentRun(
      id: "run", kind: "chat", project: "/app", status: "running", createdAt: 0,
      updatedAt: 0, request: .null, result: nil)
    store.runs = [run]
    store.library.attach(run, to: nil, note: "First")
    store.selection = run.id
    let reference = BrowserElementReference(
      url: base + "/one", pageTitle: "One", selector: "#next", tag: "a",
      text: "Next", accessibilityLabel: "", role: "link",
      rect: .init(x: 10, y: 20, width: 80, height: 24))
    store.addBrowserComment(reference, body: " Keep this link on one line ")
    let saved = store.browserComments
    store.library.browserComments["other-task"] = saved
    let restored = try JSONDecoder().decode(
      WorkspaceLibrary.self, from: JSONEncoder().encode(store.library))
    XCTAssertEqual(restored.browserComments[run.id], saved)

    store.draft = "Address the browser comments"
    await store.sendDraft()
    XCTAssertTrue(store.browserComments.isEmpty)
    XCTAssertEqual(store.library.browserComments["other-task"], saved)
    let message = try XCTUnwrap(store.library.queuedMessages.first)
    XCTAssertTrue(message.text.contains("浏览器评论"))
    XCTAssertTrue(message.text.contains("Keep this link on one line"))
    XCTAssertTrue(message.text.contains("#next"))
    XCTAssertTrue(store.draft.isEmpty)
  }
  @MainActor func testVisiblePageSnapshotIsValidPNGAndAttachesToCapturedTask() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    defer { store.workspace.browser.shutdown() }
    store.library.tasks = [
      .init(id: "task", project: "/project", title: "Task", runIDs: ["run"]),
      .init(id: "other", project: "/project", title: "Other", runIDs: ["other-run"]),
    ]
    store.selection = "run"
    store.newBrowserTab()
    let tab = try XCTUnwrap(store.workspace.browser.selected)
    tab.view.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
    try await load(tab, "/one", title: "One")

    let captured = await store.captureBrowserSnapshot(tab)
    XCTAssertTrue(captured)
    let attachment = try XCTUnwrap(store.library.draftImages["task"]?.first)
    XCTAssertEqual(attachment.mimeType, "image/png")
    XCTAssertTrue(store.library.draftImages["other"]?.isEmpty ?? true)
    let data = try ImageAttachmentStorage.data(attachment, root: root)
    XCTAssertEqual(Array(data.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
    let image = try XCTUnwrap(NSImage(data: data))
    XCTAssertGreaterThan(image.size.width, 0)
    XCTAssertGreaterThan(image.size.height, 0)
    XCTAssertNil(tab.snapshotError)
  }
  @MainActor func testSnapshotRejectsUnreadyWebViewWithoutChangingAttachments() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    defer { store.workspace.browser.shutdown() }
    store.newBrowserTab()
    let tab = try XCTUnwrap(store.workspace.browser.selected)
    tab.address = base + "/one"
    tab.navigate()
    let captured = await store.captureBrowserSnapshot(tab)
    XCTAssertFalse(captured)
    XCTAssertTrue(store.draftImages.isEmpty)
  }
  @MainActor func testBrowserElementReferenceAppendsToCurrentDraftOnly() {
    let store = WorkspaceStore()
    store.library.tasks = [
      .init(id: "task", project: "/project", title: "Task", runIDs: ["run"]),
      .init(id: "other", project: "/project", title: "Other", runIDs: ["other-run"]),
    ]
    store.selection = "run"
    store.library.drafts["task"] = "Please inspect this"
    store.library.drafts["other"] = "other draft"
    let reference = BrowserElementReference(
      url: "https://example.com/page", pageTitle: "Example", selector: "#submit",
      tag: "button", text: "Submit", accessibilityLabel: "Send form", role: "button")

    store.addBrowserElementToDraft(reference)

    XCTAssertTrue(store.library.drafts["task"]?.contains("网页元素：Send form") == true)
    XCTAssertTrue(store.library.drafts["task"]?.contains("选择器：#submit") == true)
    XCTAssertEqual(store.library.drafts["other"], "other draft")
  }
  @MainActor func testBrowserHistoryPersistsDeduplicatesAndOpensFromSettings() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    defer { store.workspace.browser.shutdown() }
    store.newBrowserTab()
    let tab = try XCTUnwrap(store.workspace.browser.selected)
    try await load(tab, "/one", title: "One")
    try await load(tab, "/two", title: "Two")
    try await load(tab, "/one", title: "One")
    XCTAssertEqual(store.library.browserHistory.map(\.title), ["One", "Two"])
    XCTAssertEqual(store.library.browserHistory.map(\.url), [base + "/one", base + "/two"])

    let entry = try XCTUnwrap(store.library.browserHistory.last)
    store.openSettings(.browser)
    store.openBrowserHistory(entry)
    XCTAssertEqual(store.destination, .workspace)
    XCTAssertEqual(store.pane, "browser")
    XCTAssertEqual(store.workspace.browser.selected?.address, base + "/two")
    try await eventually("History item did not reopen") {
      store.workspace.browser.selected?.title == "Two"
    }
    store.removeBrowserHistory(entry.id)
    XCTAssertEqual(store.library.browserHistory.map(\.title), ["One"])
    XCTAssertEqual(
      try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json")).browserHistory,
      store.library.browserHistory)
  }
  @MainActor func testClearWebsiteDataRemovesSessionCookiesAndHistoryIsOptional() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    defer { store.workspace.browser.shutdown() }
    store.newBrowserTab()
    let tab = try XCTUnwrap(store.workspace.browser.selected)
    try await load(tab, "/cookie", title: "/cookie")
    let cookieBeforeClear = try await tab.view.evaluateJavaScript("document.cookie") as? String
    XCTAssertEqual(cookieBeforeClear, "fixture=yes")
    XCTAssertEqual(store.library.browserHistory.count, 1)

    await store.clearBrowserData(includeHistory: false)
    let cookieAfterClear = try await tab.view.evaluateJavaScript("document.cookie") as? String
    XCTAssertEqual(cookieAfterClear, "")
    XCTAssertEqual(store.library.browserHistory.count, 1)
    await store.clearBrowserData(includeHistory: true)
    XCTAssertTrue(store.library.browserHistory.isEmpty)
    XCTAssertTrue(
      try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
        .browserHistory.isEmpty)
  }
  @MainActor func testMainAndTaskBrowsersShareAnIsolatedProfileAndClearItTogether() async throws {
    let shared = WKWebsiteDataStore.nonPersistent()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root, browserDataStore: shared)
    let taskBrowser = TaskWindowBrowser(dataStore: store.browserDataStore)
    store.registerBrowserSession(taskBrowser.session)
    defer {
      store.workspace.browser.shutdown()
      taskBrowser.session.shutdown()
    }
    XCTAssertTrue(store.workspace.browser.dataStore === taskBrowser.session.dataStore)
    let main = store.workspace.browser.newTab()
    try await load(main, "/cookie", title: "/cookie")
    let task = taskBrowser.session.newTab()
    try await load(task, "/one", title: "One")
    let sharedCookie = try await task.view.evaluateJavaScript("document.cookie") as? String
    XCTAssertEqual(sharedCookie, "fixture=yes")

    let isolated = BrowserSession()
    defer { isolated.shutdown() }
    let privateTab = isolated.newTab()
    try await load(privateTab, "/one", title: "One")
    let privateCookie = try await privateTab.view.evaluateJavaScript("document.cookie") as? String
    XCTAssertEqual(privateCookie, "")

    await store.clearBrowserData(includeHistory: false)
    let mainAfterClear = try await main.view.evaluateJavaScript("document.cookie") as? String
    let taskAfterClear = try await task.view.evaluateJavaScript("document.cookie") as? String
    XCTAssertEqual(mainAfterClear, "")
    XCTAssertEqual(taskAfterClear, "")
  }
  func testArrowShortcutsMatchNativeKeyEvents() throws {
    let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
      modifierFlags: [.command], timestamp: 0, windowNumber: 0, context: nil,
      characters: "\u{f702}", charactersIgnoringModifiers: "\u{f702}", isARepeat: false, keyCode: 123))
    XCTAssertEqual(ShortcutBinding(event: event), ShortcutBinding("⌘←"))
    XCTAssertEqual(ShortcutBinding("⌘←").keyboardShortcut.key, .leftArrow)
  }
  @MainActor func testTaskWindowBrowsersPreserveTaskPagesAndNeverSelectMainWorkspace() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    store.library.tasks = [
      .init(id: "main", project: "", title: "Main", runIDs: ["main-run"]),
      .init(id: "popout", project: "", title: "Popout", runIDs: ["popout-run"]),
    ]
    store.selection = "main-run"
    store.library.drafts = ["main": "Main draft", "popout": "Popout draft"]
    let windows = TaskWindowBrowsers()
    defer { windows.shutdown(); store.workspace.browser.shutdown() }
    let browser = windows.browser(for: "popout", store: store)
    let url = URL(string: base + "/one")!
    store.performMessageLinkAction(.openInApp, url: url, ownerRunID: "popout-run",
      openInApp: { browser.open($0, presentation: $1) })
    let tab = try XCTUnwrap(browser.session.selected)
    try await eventually("Independent page did not load") { !tab.loading && tab.title == "One" }
    try await tab.view.evaluateJavaScript("window.windowOwnerMarker = 91")
    browser.open(URL(string: base + "/one#section")!, presentation: .fullWidth)
    try await eventually("Independent fragment did not load") { !tab.loading && tab.committedURL?.fragment == "section" }
    XCTAssertEqual(browser.session.tabs.count, 1)
    let marker = try await tab.view.evaluateJavaScript("window.windowOwnerMarker") as? Int
    XCTAssertEqual(marker, 91)
    XCTAssertTrue(browser.fullWidth)
    _ = windows.browser(for: "main", store: store)
    XCTAssertTrue(windows.browser(for: "popout", store: store) === browser)
    let result = try XCTUnwrap(windows.results(library: store.library).first)
    browser.visible = false
    XCTAssertTrue(windows.select(result, library: store.library))
    XCTAssertTrue(browser.visible)
    XCTAssertEqual(browser.session.selection, tab.id)
    XCTAssertEqual(store.selectedTask?.id, "main")
    XCTAssertTrue(store.workspace.browser.tabs.isEmpty)
    XCTAssertEqual(store.library.drafts["main"], "Main draft")
    XCTAssertEqual(store.library.drafts["popout"], "Popout draft")
    XCTAssertEqual(store.library.browserHistory.first?.url, base + "/one",
      "History records the loaded document; fragment jumps retain the existing page")
    browser.session.close(tab.id)
    XCTAssertFalse(windows.select(result, library: store.library), "A closed search result is stale")
    XCTAssertFalse(browser.visible)
    browser.perform("browser-reopen")
    XCTAssertTrue(browser.visible)
    XCTAssertEqual(browser.session.tabs.count, 1)
    XCTAssertNotEqual(browser.session.selection, tab.id)
    let reopened = try XCTUnwrap(browser.session.selected)
    windows.shutdown()
    XCTAssertTrue(reopened.closed)
  }

  @MainActor func testIndependentBrowserBackgroundTabsAndGlobalDownloadCancellation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    let windows = TaskWindowBrowsers()
    defer { windows.shutdown(); store.workspace.browser.shutdown() }
    let browser = windows.browser(for: "task", store: store)
    let focus = browser.session.contentFocus
    browser.open(URL(string: base + "/one")!, presentation: .backgroundTab)
    let first = try XCTUnwrap(browser.session.selection)
    XCTAssertEqual(browser.session.contentFocus, focus)
    XCTAssertNil(browser.session.addressFocusTarget)
    browser.open(URL(string: base + "/two")!, presentation: .backgroundTab)
    XCTAssertEqual(browser.session.selection, first)
    XCTAssertEqual(browser.session.contentFocus, focus)
    browser.perform("next-task")
    XCTAssertNotEqual(browser.session.selection, first)
    browser.perform("tab-close-others")
    XCTAssertEqual(browser.session.tabs.count, 1)
    XCTAssertFalse(browser.commandEnabled("previous-task"))
    let id = try XCTUnwrap(browser.session.downloadLink(URL(string: base + "/download-slow")!))
    store.cancelBrowserDownload(id)
    XCTAssertEqual(store.browserDownloads.first(where: { $0.id == id })?.status, .cancelled)
    XCTAssertTrue(store.workspace.browser.tabs.isEmpty)
    let otherWindow = TaskWindowBrowsers()
    defer { otherWindow.shutdown() }
    let sameTask = otherWindow.browser(for: "task", store: store)
    XCTAssertTrue(sameTask.session.tabs.isEmpty, "Separate windows never share a WKWebView")
  }

  @MainActor func testBrowserReferencesUseExplicitTaskDraftWhenMainSelectionDiffers() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    store.library.tasks = [
      .init(id: "main", project: "", title: "Main", runIDs: ["main-run"]),
      .init(id: "popout", project: "", title: "Popout", runIDs: ["popout-run"]),
    ]
    store.selection = "main-run"
    store.library.drafts = ["main": "Main draft", "popout": "Popout draft"]
    let reference = BrowserElementReference(url: base + "/one", pageTitle: "One", selector: "h1",
      tag: "H1", text: "Fixture page", accessibilityLabel: "", role: "", rect: nil)
    store.addBrowserElementToDraft(reference, taskID: "popout")
    store.addBrowserComment(reference, body: "Only popout", taskID: "popout")
    XCTAssertEqual(store.library.drafts["main"], "Main draft")
    XCTAssertTrue(store.library.drafts["popout"]?.contains(reference.promptContext) == true)
    XCTAssertTrue(store.browserComments.isEmpty)
    XCTAssertEqual(store.browserComments(taskID: "popout").first?.body, "Only popout")
  }

}
