import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class FileSearchReturnFocusTests: XCTestCase {
  func testCancelledSearchRestoresFileTabEditorAcrossPanels() async throws {
    for placement: WorkspaceTabPlacement in [.left, .right] {
      for overlay: WorkspaceOverlay in [.fileSearch, .commands, .taskSearch] {
        for remount in [false, true] {
          let fixture = try await Fixture(placement: placement)
          defer { fixture.close() }
          let source = try XCTUnwrap(fixture.editor)
          source.setSelectedRange(NSRange(location: 4, length: 3))
          XCTAssertTrue(fixture.window.makeFirstResponder(source))
          let originalFocus = fixture.workspace.fileFocusRequest
          let composerFocus = fixture.store.focusComposer
          let target = SearchDialogReturnFocus(window: fixture.window, destination: .workspace)
          fixture.store.setOverlay(overlay, presented: true)
          fixture.store.searchDialogReturnFocus = target
          if remount { fixture.host.rootView = AnyView(TextField("Search", text: .constant(""))) }
          try await fixture.settle()
          if remount { XCTAssertNil(source.window) }
          fixture.window.makeFirstResponder(nil)
          fixture.store.setOverlay(overlay, presented: false)
          if remount {
            fixture.host.rootView = AnyView(FileSourcePreview(store: fixture.store, workspace: fixture.workspace))
          }
          fixture.store.restoreOverlayFocus()
          try await fixture.settle()
          let restored = try XCTUnwrap(fixture.editor)
          XCTAssertEqual(source === restored, !remount)
          XCTAssertNotEqual(fixture.workspace.fileFocusRequest, originalFocus, "\(placement) \(overlay)")
          XCTAssertTrue(fixture.window.firstResponder === restored, "\(placement) \(overlay)")
          XCTAssertEqual(restored.selectedRange(), NSRange(location: 4, length: 3))
          XCTAssertEqual(fixture.store.focusComposer, composerFocus)
          XCTAssertNil(fixture.store.searchDialogReturnFocus)
        }
      }
    }
  }

  func testSearchReturnDoesNotFocusAChangedFileOrInactivePanel() async throws {
    let fixture = try await Fixture(placement: .left)
    defer { fixture.close() }
    for change in ["file", "tab", "window", "overlay", "destination"] {
      fixture.store.destination = .workspace
      fixture.store.activeWorkspaceTabID = fixture.tab.id
      fixture.store.focusedWorkspaceTabID = fixture.tab.id
      fixture.workspace.selectedFile = "File.swift"
      fixture.window.acceptsFocus = true
      fixture.store.presentedOverlay = nil
      XCTAssertTrue(fixture.window.makeFirstResponder(try XCTUnwrap(fixture.editor)))
      let target = SearchDialogReturnFocus(window: fixture.window, destination: .workspace)
      fixture.store.setOverlay(.fileSearch, presented: true)
      fixture.store.searchDialogReturnFocus = target
      fixture.window.makeFirstResponder(nil)
      fixture.store.setOverlay(.fileSearch, presented: false)
      switch change {
      case "file": fixture.workspace.selectedFile = "Other.swift"
      case "tab": fixture.store.activeWorkspaceTabID = nil
      case "window": fixture.window.acceptsFocus = false
      case "overlay": fixture.store.presentedOverlay = .commands
      default: fixture.store.destination = .settings
      }
      let focus = fixture.workspace.fileFocusRequest
      fixture.store.restoreOverlayFocus()
      try await fixture.settle()
      XCTAssertEqual(fixture.workspace.fileFocusRequest, focus, change)
      XCTAssertFalse(fixture.window.firstResponder is FilePreviewTextView, change)
    }
  }

  func testPendingReturnCannotStealFocusFromAReplacementDialogOrTab() async throws {
    let fixture = try await Fixture(placement: .left)
    defer { fixture.close() }
    for change in ["dialog", "tab", "destination"] {
      fixture.store.destination = .workspace
      fixture.store.activeWorkspaceTabID = fixture.tab.id
      fixture.store.focusedWorkspaceTabID = fixture.tab.id
      fixture.store.presentedOverlay = nil
      XCTAssertTrue(fixture.window.makeFirstResponder(try XCTUnwrap(fixture.editor)))
      let target = SearchDialogReturnFocus(window: fixture.window, destination: .workspace)
      fixture.store.setOverlay(.fileSearch, presented: true)
      fixture.store.searchDialogReturnFocus = target
      fixture.window.makeFirstResponder(nil)
      fixture.store.setOverlay(.fileSearch, presented: false)
      fixture.store.restoreOverlayFocus()
      let query = NSTextField(frame: .init(x: 0, y: 0, width: 200, height: 24))
      fixture.host.addSubview(query)
      XCTAssertTrue(fixture.window.makeFirstResponder(query))
      switch change {
      case "dialog": fixture.store.setOverlay(.commands, presented: true)
      case "tab": fixture.store.activateChatTab()
      default: fixture.store.destination = .settings
      }
      try await fixture.settle()
      XCTAssertTrue(fixture.window.firstResponder === query.currentEditor(), change)
      query.removeFromSuperview()
    }
  }

  func testIndependentFileWindowCanFocusWhileMainWindowHasASearchDialog() async throws {
    let fixture = try await Fixture(placement: .left)
    defer { fixture.close() }
    fixture.window.identifier = NSUserInterfaceItemIdentifier("task-independent")
    fixture.store.destination = .settings
    fixture.store.presentedOverlay = .commands
    fixture.window.makeFirstResponder(nil)
    fixture.workspace.fileFocusRequest = UUID()
    try await fixture.settle()
    XCTAssertTrue(fixture.window.firstResponder === fixture.editor)
  }

  @MainActor private final class Fixture {
    let store: WorkspaceStore
    let workspace: DeveloperWorkspace
    let tab: WorkspaceContentTab
    let window: SearchReturnTestWindow
    let host: NSHostingView<AnyView>
    var editor: FilePreviewTextView? {
      func find(_ view: NSView) -> FilePreviewTextView? {
        if let text = view as? FilePreviewTextView { return text }
        return view.subviews.compactMap(find).first
      }
      return find(host)
    }
    init(placement: WorkspaceTabPlacement) async throws {
      _ = NSApplication.shared
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      store = WorkspaceStore(dataRoot: root)
      store.libraryLoaded = true; store.scopeLoaded = true; store.connected = true
      store.project = root; store.workspace.root = root
      store.library.tasks = [.init(id: "task", project: root.path, title: "Task", runIDs: [])]
      store.selection = "task"
      XCTAssertTrue(store.openFileTab("File.swift", in: placement))
      tab = try XCTUnwrap(store.visibleWorkspaceContentTabs.first)
      workspace = store.fileTabWorkspace(tab)
      workspace.root = root; workspace.selectedFile = "File.swift"
      workspace.openFiles = ["File.swift"]; workspace.fileText = "let one = 1\nlet two = 2"
      window = SearchReturnTestWindow(contentRect: .init(x: 0, y: 0, width: 500, height: 350),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.identifier = NSUserInterfaceItemIdentifier("main")
      host = NSHostingView(rootView: AnyView(FileSourcePreview(store: store, workspace: workspace)))
      window.contentView = host
      try await settle()
    }
    func close() {
      window.contentView = nil
      window.close()
      try? FileManager.default.removeItem(at: store.dataRoot)
    }
    func settle() async throws {
      try await Task.sleep(for: .milliseconds(100))
      host.layoutSubtreeIfNeeded()
    }
  }
}

private final class SearchReturnTestWindow: NSWindow {
  var acceptsFocus = true
  override var isKeyWindow: Bool { acceptsFocus }
}
