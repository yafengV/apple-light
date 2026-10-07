import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class SettingsReturnFocusTests: XCTestCase {
  func testSettingsReturnRestoresContentAndInspectorFileEditors() async throws {
    for location in ["left", "right", "inspector"] {
      let fixture = try await Fixture(location: location)
      defer { fixture.close() }
      let source = try XCTUnwrap(fixture.editor)
      XCTAssertTrue(fixture.window.makeFirstResponder(source))
      source.setSelectedRange(NSRange(location: 4, length: 3))
      let composer = fixture.store.focusComposer
      fixture.store.openSettings(.general)
      fixture.focusQuery()
      fixture.store.openSettings(.voice)
      fixture.store.openSettings()
      fixture.store.closeSettings()
      try await fixture.settle()
      XCTAssertEqual(fixture.store.destination, .workspace)
      XCTAssertTrue(fixture.window.firstResponder === source, location)
      XCTAssertEqual(source.selectedRange(), NSRange(location: 4, length: 3))
      XCTAssertEqual(fixture.store.focusComposer, composer, location)
    }
  }

  func testSettingsReturnRestoresOriginalStandalonePageField() async throws {
    for page: AppDestination in [.projects, .plugins, .skills, .automations] {
      let fixture = try await Fixture(location: "left")
      defer { fixture.close() }
      fixture.store.destination = page
      let original = NSTextField(frame: .init(x: 0, y: 60, width: 200, height: 24))
      original.stringValue = "Keep original query"
      fixture.host.addSubview(original)
      XCTAssertTrue(fixture.window.makeFirstResponder(original))
      fixture.store.openSettings(.general)
      fixture.focusQuery()
      fixture.store.closeSettings()
      try await fixture.settle()
      XCTAssertEqual(fixture.store.destination, page)
      XCTAssertTrue(fixture.window.firstResponder === original.currentEditor(), "\(page)")
      XCTAssertEqual(original.stringValue, "Keep original query")
    }
  }

  func testPaletteSettingsKeepTheOriginalFileSourceInsteadOfSearchField() async throws {
    let fixture = try await Fixture(location: "right")
    defer { fixture.close() }
    let source = try XCTUnwrap(fixture.editor)
    XCTAssertTrue(fixture.window.makeFirstResponder(source))
    let target = SearchDialogReturnFocus(window: fixture.window, destination: .workspace)
    fixture.store.setOverlay(.commands, presented: true)
    fixture.store.searchDialogReturnFocus = target
    fixture.focusQuery()
    XCTAssertTrue(fixture.store.paletteCommandEnabled("settings"))
    fixture.store.executePaletteCommand("settings")
    XCTAssertEqual(fixture.store.destination, .settings)
    try await fixture.settle()
    XCTAssertFalse(fixture.window.firstResponder === source)
    fixture.store.closeSettings()
    try await fixture.settle()
    XCTAssertTrue(fixture.window.firstResponder === source)
    XCTAssertNil(fixture.store.presentedOverlay)
  }

  func testUnsavedConfirmationRetainsSourceUntilExitActuallyCompletes() async throws {
    let fixture = try await Fixture(location: "left")
    defer { fixture.close() }
    let source = try XCTUnwrap(fixture.editor)
    XCTAssertTrue(fixture.window.makeFirstResponder(source))
    fixture.store.openSettings(.model)
    fixture.focusQuery()
    let focus = fixture.workspace.fileFocusRequest
    fixture.store.modelSettingsDirty = true
    fixture.store.closeSettings()
    XCTAssertEqual(fixture.store.destination, .settings)
    XCTAssertEqual(fixture.store.pendingSettingsNavigation, .close)
    XCTAssertEqual(fixture.workspace.fileFocusRequest, focus)
    fixture.store.cancelDiscardSettingsChanges()
    fixture.store.closeSettings()
    fixture.store.confirmDiscardSettingsChanges()
    try await fixture.settle()
    XCTAssertEqual(fixture.store.destination, .workspace)
    XCTAssertTrue(fixture.window.firstResponder === source)
  }

  func testSettingsReturnRejectsChangedFileAndInactiveSourceWindow() async throws {
    let fixture = try await Fixture(location: "left")
    defer { fixture.close() }
    for change in ["file", "window"] {
      fixture.workspace.selectedFile = "File.swift"
      fixture.window.acceptsFocus = true
      XCTAssertTrue(fixture.window.makeFirstResponder(try XCTUnwrap(fixture.editor)))
      fixture.store.openSettings(.general)
      fixture.focusQuery()
      if change == "file" { fixture.workspace.selectedFile = "Other.swift" }
      else { fixture.window.acceptsFocus = false }
      let focus = fixture.workspace.fileFocusRequest
      fixture.store.closeSettings()
      try await fixture.settle()
      XCTAssertEqual(fixture.workspace.fileFocusRequest, focus)
      XCTAssertFalse(fixture.window.firstResponder is FilePreviewTextView, change)
    }
  }

  func testWorkspaceFieldsDoNotRestoreIntoAChangedTaskOrProject() async throws {
    let fixture = try await Fixture(location: "left")
    defer { fixture.close() }
    let original = NSTextField(frame: .init(x: 0, y: 60, width: 200, height: 24))
    fixture.host.addSubview(original)
    for change in ["task", "project"] {
      fixture.store.selection = "task"
      fixture.store.project = fixture.store.dataRoot
      XCTAssertTrue(fixture.window.makeFirstResponder(original))
      fixture.store.openSettings(.general)
      fixture.focusQuery()
      if change == "task" { fixture.store.selection = "other" }
      else { fixture.store.project = fixture.store.dataRoot.appendingPathComponent("Other") }
      fixture.store.closeSettings()
      try await fixture.settle()
      XCTAssertFalse(fixture.window.firstResponder === original.currentEditor(), change)
      XCTAssertTrue(fixture.window.firstResponder === fixture.query.currentEditor(), change)
    }
  }

  func testReenteredSettingsInvalidateThePreviousQueuedFieldRestoration() async throws {
    let fixture = try await Fixture(location: "left")
    defer { fixture.close() }
    fixture.store.destination = .projects
    let first = SettingsFocusField(frame: .init(x: 0, y: 60, width: 200, height: 24))
    let second = SettingsFocusField(frame: .init(x: 0, y: 100, width: 200, height: 24))
    fixture.host.addSubview(first); fixture.host.addSubview(second)
    XCTAssertTrue(fixture.window.makeFirstResponder(first))
    XCTAssertGreaterThan(first.acquisitions, 0)
    let acquisitions = first.acquisitions
    fixture.store.openSettings(.general)
    fixture.focusQuery()
    fixture.store.closeSettings()
    // The first close has queued an AppKit callback, but a second entry already
    // belongs to a different control on the retained page.
    XCTAssertTrue(fixture.window.makeFirstResponder(second))
    fixture.store.openSettings(.general)
    fixture.focusQuery()
    fixture.store.closeSettings()
    try await fixture.settle()
    XCTAssertEqual(first.acquisitions, acquisitions, "An obsolete close must not refocus its old control")
    XCTAssertTrue(fixture.window.firstResponder === second.currentEditor())
  }

  @MainActor private final class Fixture {
    let store: WorkspaceStore
    let workspace: DeveloperWorkspace
    let window: SettingsReturnTestWindow
    let host: NSHostingView<FileSourcePreview>
    let query = NSTextField(frame: .init(x: 0, y: 0, width: 200, height: 24))
    var editor: FilePreviewTextView? {
      func find(_ view: NSView) -> FilePreviewTextView? {
        if let text = view as? FilePreviewTextView { return text }
        return view.subviews.compactMap(find).first
      }
      return find(host)
    }
    init(location: String) async throws {
      _ = NSApplication.shared
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      store = WorkspaceStore(dataRoot: root)
      store.libraryLoaded = true; store.scopeLoaded = true; store.connected = true
      store.project = root; store.workspace.root = root
      store.library.tasks = [.init(id: "task", project: root.path, title: "Task", runIDs: [])]
      store.selection = "task"
      if location == "inspector" {
        workspace = store.workspace
        store.showingInspector = true; store.pane = "files"
      } else {
        XCTAssertTrue(store.openFileTab("File.swift", in: location == "left" ? .left : .right))
        workspace = store.fileTabWorkspace(try XCTUnwrap(store.visibleWorkspaceContentTabs.first))
      }
      workspace.root = root; workspace.selectedFile = "File.swift"
      workspace.openFiles = ["File.swift"]; workspace.fileText = "let one = 1\nlet two = 2"
      window = SettingsReturnTestWindow(contentRect: .init(x: 0, y: 0, width: 500, height: 350),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.identifier = NSUserInterfaceItemIdentifier("main")
      host = NSHostingView(rootView: FileSourcePreview(store: store, workspace: workspace))
      window.contentView = host
      host.addSubview(query)
      try await settle()
    }
    func focusQuery() { XCTAssertTrue(window.makeFirstResponder(query)) }
    func close() {
      window.contentView = nil; window.close()
      try? FileManager.default.removeItem(at: store.dataRoot)
    }
    func settle() async throws {
      try await Task.sleep(for: .milliseconds(100))
      host.layoutSubtreeIfNeeded()
    }
  }
}

private final class SettingsReturnTestWindow: NSWindow {
  var acceptsFocus = true
  override var isKeyWindow: Bool { acceptsFocus }
}

private final class SettingsFocusField: NSTextField {
  var acquisitions = 0
  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted { acquisitions += 1 }
    return accepted
  }
}
