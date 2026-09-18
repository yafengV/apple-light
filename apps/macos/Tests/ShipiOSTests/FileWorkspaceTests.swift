import XCTest
@testable import ShipiOS

@MainActor
final class FileWorkspaceTests: XCTestCase {
  @MainActor private final class Reads {
    var pending: [String: CheckedContinuation<String, Error>] = [:]
    func read(_ path: String) async throws -> String {
      try await withCheckedThrowingContinuation { pending[path] = $0 }
    }
    func wait(_ path: String) async {
      for _ in 0..<1000 {
        if pending[path] != nil { return }
        await Task.yield()
      }
      XCTFail("Read did not start: \(path)")
    }
    func finish(_ path: String, _ result: Result<String, Error>) { pending.removeValue(forKey: path)?.resume(with: result) }
  }

  func testClosingLoadingFileIgnoresLateResultAndError() async {
    for failure in [false, true] {
      let reads = Reads()
      let workspace = DeveloperWorkspace(fileReader: { path, _ in try await reads.read(path) })
      workspace.root = URL(fileURLWithPath: "/fixture")
      let load = workspace.selectFile("closed.swift")
      await reads.wait("closed.swift")
      workspace.closeFile("closed.swift")
      reads.finish("closed.swift", failure ? .failure(AgentFailure(message: "late error")) : .success("late text"))
      await load?.value
      XCTAssertNil(workspace.selectedFile)
      XCTAssertTrue(workspace.openFiles.isEmpty)
      XCTAssertEqual(workspace.fileText, "")
      XCTAssertNil(workspace.fileError)
      XCTAssertFalse(workspace.fileLoading)
    }
  }

  func testOutOfOrderReadsCannotReplaceSelectedTab() async {
    let reads = Reads()
    let workspace = DeveloperWorkspace(fileReader: { path, _ in try await reads.read(path) })
    workspace.root = URL(fileURLWithPath: "/fixture")
    let first = workspace.selectFile("first")
    await reads.wait("first")
    let second = workspace.selectFile("second")
    await reads.wait("second")
    reads.finish("second", .success("second text")); await second?.value
    reads.finish("first", .success("first text")); await first?.value
    XCTAssertEqual(workspace.selectedFile, "second")
    XCTAssertEqual(workspace.fileText, "second text")
    XCTAssertFalse(workspace.fileLoading)
    workspace.closeFile("first")
    XCTAssertEqual(workspace.fileText, "second text")
  }

  func testCloseFallbackCannotReopenTabOrOverrideProjectChange() async {
    let reads = Reads()
    let workspace = DeveloperWorkspace(fileReader: { path, _ in try await reads.read(path) })
    workspace.root = URL(fileURLWithPath: "/fixture")
    workspace.openFiles = ["first", "second", "third"]
    workspace.selectedFile = "second"
    workspace.closeFile("second")
    XCTAssertEqual(workspace.selectedFile, "third")
    await reads.wait("third")
    workspace.closeFile("third")
    XCTAssertEqual(workspace.selectedFile, "first")
    await reads.wait("first")
    workspace.setProject(nil)
    reads.finish("third", .success("closed"))
    reads.finish("first", .success("old project"))
    for _ in 0..<20 { await Task.yield() }
    XCTAssertNil(workspace.selectedFile)
    XCTAssertTrue(workspace.openFiles.isEmpty)
    XCTAssertEqual(workspace.fileText, "")
    XCTAssertFalse(workspace.fileLoading)
  }

  func testFailedFileCanRetryAndDoesNotOverwriteReviewError() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = DeveloperWorkspace()
    workspace.root = root
    workspace.error = "review error"
    await workspace.openFile("new.swift")
    XCTAssertNotNil(workspace.fileError)
    XCTAssertEqual(workspace.error, "review error")
    try "恢复内容 👩🏽‍💻\n".write(to: root.appendingPathComponent("new.swift"), atomically: true, encoding: .utf8)
    await workspace.openFile("new.swift")
    XCTAssertNil(workspace.fileError)
    XCTAssertEqual(workspace.fileText, "恢复内容 👩🏽‍💻\n")
    XCTAssertEqual(workspace.openFiles, ["new.swift"])
  }

  func testFileCommandsRespectSettingsOverlayAndLastTabFocus() async {
    let store = WorkspaceStore()
    store.workspace = DeveloperWorkspace(fileReader: { path, _ in path })
    store.workspace.root = URL(fileURLWithPath: "/fixture")
    store.showingInspector = true
    store.pane = "files"
    await store.workspace.openFile("first")
    await store.workspace.openFile("second")
    let originalFocus = store.focusComposer
    XCTAssertTrue(store.handleFileShortcut(ShortcutBinding("⌃⇧⇥")))
    XCTAssertEqual(store.workspace.selectedFile, "first")
    XCTAssertTrue(store.handleFileShortcut(ShortcutBinding("⌃⇧⇥")))
    XCTAssertEqual(store.workspace.selectedFile, "second")
    store.openSettings(.general)
    XCTAssertFalse(store.handleFileShortcut(ShortcutBinding("⌘W")))
    XCTAssertEqual(store.workspace.openFiles.count, 2)
    store.closeSettings()
    store.showingFileSearch = true
    XCTAssertFalse(store.handleFileShortcut(ShortcutBinding("⌃⇥")))
    store.showingFileSearch = false
    XCTAssertTrue(store.handleFileShortcut(ShortcutBinding("⌘W")))
    XCTAssertEqual(store.workspace.selectedFile, "first")
    XCTAssertTrue(store.handleFileShortcut(ShortcutBinding("⌘W")))
    XCTAssertTrue(store.workspace.openFiles.isEmpty)
    XCTAssertNotEqual(store.focusComposer, originalFocus)
    XCTAssertTrue(store.showingInspector)
    XCTAssertFalse(store.handleFileShortcut(ShortcutBinding("⌘W")))
  }

  func testSearchDismissalFocusOnlyReturnsToMatchingFileScope() async {
    let store = WorkspaceStore()
    store.workspace = DeveloperWorkspace(fileReader: { path, _ in path })
    let root = URL(fileURLWithPath: "/fixture")
    store.workspace.root = root
    store.pane = "files"; store.showingInspector = true
    await store.workspace.openFile("first")
    let composerFocus = store.focusComposer
    let fileFocus = store.workspace.fileFocusRequest
    store.fileFocusAfterOverlay = (root, "first")
    store.restoreOverlayFocus()
    XCTAssertNotEqual(store.workspace.fileFocusRequest, fileFocus)
    XCTAssertEqual(store.focusComposer, composerFocus)
    store.fileFocusAfterOverlay = (root, "other")
    store.restoreOverlayFocus()
    XCTAssertNotEqual(store.focusComposer, composerFocus)
    store.fileFocusAfterOverlay = (root, "first")
    store.openSettings()
    let focusInSettings = store.focusComposer
    store.restoreOverlayFocus()
    XCTAssertEqual(store.focusComposer, focusInSettings)
    XCTAssertNil(store.fileFocusAfterOverlay)
  }

  func testLineSelectionUsesNativeUnicodeOffsetsAndRejectsInvalidLines() {
    let text = "👩🏽‍💻 Café\r\n中文\nlast"
    let range = FileLineLocation.range("2", in: text)!
    XCTAssertEqual((text as NSString).substring(with: range), "中文")
    XCTAssertEqual((text as NSString).substring(with: FileLineLocation.range("3", in: text)!), "last")
    for value in ["0", "-1", "4", "abc", "1:2", "999999999999999999999999999"] {
      XCTAssertNil(FileLineLocation.range(value, in: text), value)
    }
    XCTAssertEqual(FileLineLocation.range("2", in: "first\n"), NSRange(location: 6, length: 0))
    XCTAssertEqual(FileLineLocation.range("1", in: ""), NSRange(location: 0, length: 0))
    XCTAssertNil(FileLineLocation.range("2", in: ""))
  }
}
