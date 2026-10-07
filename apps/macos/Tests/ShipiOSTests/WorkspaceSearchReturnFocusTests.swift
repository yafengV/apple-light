import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class WorkspaceSearchReturnFocusTests: XCTestCase {
  func testCancelledSearchRestoresWorkspaceFieldAndItsSelection() async throws {
    for overlay: WorkspaceOverlay in [.commands, .taskSearch, .fileSearch, .projectPicker] {
      let fixture = try await Fixture()
      defer { fixture.close() }
      XCTAssertTrue(fixture.window.makeFirstResponder(fixture.first))
      fixture.first.currentEditor()?.selectedRange = .init(location: 2, length: 3)
      let composer = fixture.store.focusComposer
      fixture.begin(overlay)
      fixture.cancel(overlay)
      try await fixture.settle()
      XCTAssertTrue(fixture.window.firstResponder === fixture.first.currentEditor(), "\(overlay)")
      XCTAssertEqual(fixture.first.currentEditor()?.selectedRange, .init(location: 2, length: 3))
      XCTAssertEqual(fixture.first.stringValue, "中文 original🙂")
      XCTAssertEqual(fixture.store.focusComposer, composer, "Cancelling must not redirect input to the parent composer")
    }
  }

  func testChildComposerReturnWaitsForTheRetainedPageToBecomeEnabled() async throws {
    for overlay: WorkspaceOverlay in [.commands, .taskSearch, .fileSearch, .projectPicker] {
      let fixture = try await Fixture()
      defer { fixture.close() }
      let editor = try XCTUnwrap(fixture.editor)
      XCTAssertTrue(fixture.window.makeFirstResponder(editor))
      editor.setSelectedRange(.init(location: 2, length: 3))
      let composer = fixture.store.focusComposer
      fixture.begin(overlay)
      fixture.state.enabled = false; try await fixture.settle()
      XCTAssertFalse(editor.isEditable)
      fixture.cancel(overlay)
      try await fixture.settle()
      XCTAssertTrue(fixture.window.firstResponder === fixture.query.currentEditor())
      fixture.state.enabled = true; try await fixture.settle()
      XCTAssertTrue(fixture.window.firstResponder === editor, "\(overlay)")
      XCTAssertEqual(editor.selectedRange(), .init(location: 2, length: 3))
      XCTAssertEqual(fixture.state.text, "中文 child draft🙂")
      XCTAssertEqual(fixture.store.focusComposer, composer)
    }
  }

  func testPendingReturnRejectsChangedScopeReplacementModalAndInactiveOrRemovedSource() async throws {
    for change in ["task", "project", "page", "search", "preview", "window", "hidden", "removed"] {
      let fixture = try await Fixture()
      defer { fixture.close() }
      let editor = try XCTUnwrap(fixture.editor)
      XCTAssertTrue(fixture.window.makeFirstResponder(editor))
      let composer = fixture.store.focusComposer
      fixture.begin(.commands)
      fixture.state.enabled = false; try await fixture.settle()
      fixture.cancel(.commands)
      switch change {
      case "task": fixture.store.selection = "other"
      case "project": fixture.store.project = fixture.store.dataRoot
      case "page": fixture.store.destination = .skills
      case "search": fixture.store.setOverlay(.taskSearch, presented: true)
      case "preview": fixture.store.setOverlay(.imagePreview, presented: true)
      case "window": fixture.window.acceptsFocus = false
      case "hidden": editor.isHidden = true
      default: fixture.host.rootView = AnyView(EmptyView())
      }
      fixture.state.enabled = true; try await fixture.settle()
      XCTAssertTrue(fixture.window.firstResponder === fixture.query.currentEditor(), change)
      XCTAssertEqual(fixture.store.focusComposer, composer, change)
    }
  }

  func testReenteredSearchInvalidatesAnEarlierQueuedFieldReturn() async throws {
    for destination: AppDestination in [.workspace, .skills] {
      let fixture = try await Fixture()
      defer { fixture.close() }
      fixture.store.destination = destination
      XCTAssertTrue(fixture.window.makeFirstResponder(fixture.first))
      let acquisitions = fixture.first.acquisitions
      fixture.begin(.commands); fixture.cancel(.commands)
      XCTAssertTrue(fixture.window.makeFirstResponder(fixture.second))
      fixture.begin(.taskSearch); fixture.cancel(.taskSearch)
      try await fixture.settle()
      XCTAssertEqual(fixture.first.acquisitions, acquisitions,
        "The first close must not reacquire a shared field editor after a newer search")
      XCTAssertTrue(fixture.window.firstResponder === fixture.second.currentEditor())
    }
  }

  func testSearchEntryCapturesTheActiveMainWindow() async throws {
    let fixtures = [try await Fixture(), try await Fixture()]
    defer { fixtures.forEach { $0.close() } }
    let first = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "main" })
    let source = try XCTUnwrap(fixtures.first { $0.window !== first })
    for fixture in fixtures { fixture.window.acceptsFocus = fixture === source }
    XCTAssertTrue(source.window.makeFirstResponder(source.first))
    source.store.setOverlay(.commands, presented: true)
    XCTAssertTrue(source.store.searchDialogReturnFocus?.window === source.window)
    XCTAssertTrue(source.store.searchDialogReturnFocus?.view === source.first)
    XCTAssertTrue(source.window.makeFirstResponder(source.query))
    source.store.setOverlay(.taskSearch, presented: true)
    XCTAssertTrue(source.store.searchDialogReturnFocus?.view === source.first,
      "Changing search modes must retain the original control")
    source.cancel(.taskSearch); try await source.settle()
    XCTAssertTrue(source.window.firstResponder === source.first.currentEditor())
  }

  func testCancelledSearchRestoresTheActualTerminalView() async throws {
    let fixture = try await Fixture()
    defer { fixture.close() }
    let terminal = SessionTerminalView(frame: .init(x: 0, y: 220, width: 300, height: 100))
    fixture.host.addSubview(terminal)
    for overlay: WorkspaceOverlay in [.commands, .taskSearch, .fileSearch, .projectPicker] {
      XCTAssertTrue(fixture.window.makeFirstResponder(terminal))
      let composer = fixture.store.focusComposer
      fixture.begin(overlay); fixture.cancel(overlay)
      try await fixture.settle()
      XCTAssertTrue(fixture.window.firstResponder === terminal, "\(overlay)")
      XCTAssertEqual(fixture.store.focusComposer, composer)
    }
  }

  func testSelectingAnAlreadyOpenFileFocusesItsEditorInsteadOfTheSearchSource() async throws {
    let fixture = try await Fixture()
    defer { fixture.close() }
    let root = fixture.store.dataRoot
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "let value = 1".write(to: root.appendingPathComponent("File.swift"), atomically: true, encoding: .utf8)
    fixture.store.project = root; fixture.store.workspace.root = root
    fixture.store.library.tasks[0].project = root.path
    XCTAssertTrue(fixture.store.openFileTab("File.swift"))
    let tab = try XCTUnwrap(fixture.store.focusedWorkspaceContentTab)
    let workspace = fixture.store.fileTabWorkspace(tab)
    workspace.root = root; workspace.selectedFile = "File.swift"
    workspace.openFiles = ["File.swift"]; workspace.fileText = "let value = 1"
    fixture.host.rootView = AnyView(FileSourcePreview(store: fixture.store, workspace: workspace))
    try await fixture.settle()
    let terminal = SessionTerminalView(frame: .init(x: 0, y: 220, width: 300, height: 100))
    fixture.host.addSubview(terminal)
    XCTAssertTrue(fixture.window.makeFirstResponder(terminal))
    let composer = fixture.store.focusComposer
    let fileFocus = workspace.fileFocusRequest
    fixture.begin(.fileSearch)
    XCTAssertTrue(fixture.store.openFileSearchResult("File.swift"))
    try await fixture.settle()
    XCTAssertNil(fixture.store.presentedOverlay)
    XCTAssertNil(fixture.store.searchDialogReturnFocus)
    XCTAssertNil(fixture.store.fileFocusAfterOverlay)
    XCTAssertNotEqual(workspace.fileFocusRequest, fileFocus)
    XCTAssertTrue((fixture.window.firstResponder as? FilePreviewTextView)?.workspace === workspace)
    XCTAssertEqual(fixture.store.focusComposer, composer)
    XCTAssertFalse(fixture.window.firstResponder === terminal)
  }

  func testRejectedOrStaleFileResultDoesNotDismissAnotherDialogOrLoseItsSource() async throws {
    let fixture = try await Fixture()
    defer { fixture.close() }
    fixture.store.project = fixture.store.dataRoot
    fixture.store.workspace.root = fixture.store.dataRoot
    fixture.store.library.tasks[0].project = fixture.store.dataRoot.path
    XCTAssertTrue(fixture.window.makeFirstResponder(fixture.first))
    fixture.begin(.fileSearch)
    XCTAssertFalse(fixture.store.openFileSearchResult("../outside.swift"))
    XCTAssertEqual(fixture.store.presentedOverlay, .fileSearch)
    XCTAssertTrue(fixture.store.searchDialogReturnFocus?.view === fixture.first)
    XCTAssertTrue(fixture.window.firstResponder === fixture.query.currentEditor())
    fixture.store.cancelFileSearch(); try await fixture.settle()
    XCTAssertTrue(fixture.window.firstResponder === fixture.first.currentEditor())
    fixture.begin(.commands)
    XCTAssertFalse(fixture.store.openFileSearchResult("File.swift"))
    fixture.store.cancelFileSearch()
    XCTAssertEqual(fixture.store.presentedOverlay, .commands)
    XCTAssertTrue(fixture.window.firstResponder === fixture.query.currentEditor())
  }

  func testFieldReturnDoesNotApplyAnOldSelectionToAnUpdatedValue() async throws {
    let fixture = try await Fixture()
    defer { fixture.close() }
    XCTAssertTrue(fixture.window.makeFirstResponder(fixture.first))
    fixture.first.currentEditor()?.selectedRange = .init(location: 2, length: 3)
    fixture.begin(.commands)
    fixture.first.stringValue = "replacement value"
    fixture.cancel(.commands); try await fixture.settle()
    XCTAssertTrue(fixture.window.firstResponder === fixture.first.currentEditor())
    XCTAssertEqual(fixture.first.currentEditor()?.selectedRange,
      .init(location: 0, length: fixture.first.stringValue.utf16.count))
  }

  @MainActor private final class Fixture {
    let state = SearchComposerState()
    let store: WorkspaceStore
    let window: SearchFocusWindow
    let host: NSHostingView<AnyView>
    let first = SearchFocusField(frame: .init(x: 0, y: 100, width: 200, height: 24))
    let second = SearchFocusField(frame: .init(x: 0, y: 140, width: 200, height: 24))
    let query = NSTextField(frame: .init(x: 0, y: 180, width: 200, height: 24))
    var editor: ComposerNativeTextView? {
      func find(_ view: NSView) -> ComposerNativeTextView? {
        (view as? ComposerNativeTextView) ?? view.subviews.compactMap(find).first
      }
      return find(host)
    }
    init() async throws {
      _ = NSApplication.shared
      store = WorkspaceStore(dataRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
      store.libraryLoaded = true; store.scopeLoaded = true; store.connected = true
      store.library.tasks = [.init(id: "task", project: "", title: "Parent", runIDs: [])]
      store.selection = "task"
      window = SearchFocusWindow(contentRect: .init(x: 0, y: 0, width: 500, height: 350),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false; window.identifier = .init("main")
      host = NSHostingView(rootView: AnyView(SearchComposerFixtureView(state: state)))
      window.contentView = host
      first.stringValue = "中文 original🙂"
      for field in [first, second, query] { host.addSubview(field) }
      try await settle()
    }
    func begin(_ overlay: WorkspaceOverlay) {
      store.setOverlay(overlay, presented: true)
      XCTAssertTrue(window.makeFirstResponder(query))
    }
    func cancel(_ overlay: WorkspaceOverlay) {
      store.setOverlay(overlay, presented: false); store.restoreOverlayFocus()
    }
    func settle() async throws { try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded() }
    func close() {
      window.acceptsFocus = false; window.contentView = nil; window.close()
      try? FileManager.default.removeItem(at: store.dataRoot)
    }
  }
}

@MainActor private final class SearchComposerState: ObservableObject {
  @Published var enabled = true
  @Published var text = "中文 child draft🙂"
}

private struct SearchComposerFixtureView: View {
  @ObservedObject var state: SearchComposerState
  var body: some View {
    SubagentComposerView(text: $state.text, plainTextMode: true, sendShortcut: .commandEnter,
      working: false, sending: false, stopping: false, canSend: true, canStop: false,
      stopError: nil, previousPrompt: nil, send: {}, stop: {}).disabled(!state.enabled)
  }
}

private final class SearchFocusWindow: NSWindow {
  var acceptsFocus = true
  override var isKeyWindow: Bool { acceptsFocus }
}

private final class SearchFocusField: NSTextField {
  var acquisitions = 0
  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted { acquisitions += 1 }
    return accepted
  }
}
