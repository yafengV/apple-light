import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class FilePreviewFocusTests: XCTestCase {
  func testSelectionEditRequiresReviewAndKeepsNativeUndo() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "one two".write(to: root.appendingPathComponent("Edit.swift"), atomically: true, encoding: .utf8)
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"))
    let workspace = DeveloperWorkspace()
    workspace.root = root
    await workspace.openFile("Edit.swift")
    let window = FilePreviewTestWindow(contentRect: .init(x: 0, y: 0, width: 500, height: 350),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: FileSourcePreview(store: store, workspace: workspace))
    window.contentView = host
    host.frame.size = .init(width: 500, height: 350)
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    func preview(_ view: NSView) -> FilePreviewTextView? {
      if let text = view as? FilePreviewTextView { return text }
      return view.subviews.compactMap(preview).first
    }
    let text = try XCTUnwrap(preview(host))
    text.setSelectedRange(NSRange(location: 3, length: 1))
    workspace.selectionEdit.selectionChanged(in: text)
    XCTAssertNil(workspace.selectionEdit.candidate, "Whitespace-only selections have no edit action")
    text.setSelectedRange(NSRange(location: 4, length: 3))
    workspace.selectionEdit.selectionChanged(in: text)
    workspace.selectionEdit.open(path: "Edit.swift", source: workspace.fileText)
    workspace.selectionEdit.instruction = "uppercase"
    workspace.selectionEdit.generate { request in
      try request.proposal(from: "TWO")
    }
    for _ in 0..<20 where workspace.selectionEdit.proposal == nil {
      await Task.yield()
    }
    XCTAssertNotNil(workspace.selectionEdit.proposal)
    XCTAssertEqual(text.string, "one two", "Generating must not modify the editor")
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Edit.swift")), "one two")
    workspace.selectionEdit.revise()
    XCTAssertNil(workspace.selectionEdit.proposal)
    XCTAssertEqual(workspace.selectionEdit.instruction, "uppercase")
    workspace.selectionEdit.generate { request in try request.proposal(from: "TWO") }
    for _ in 0..<20 where workspace.selectionEdit.proposal == nil { await Task.yield() }
    XCTAssertTrue(workspace.selectionEdit.accept(path: workspace.selectedFile, source: workspace.fileText))
    XCTAssertEqual(workspace.fileText, "one TWO")
    XCTAssertTrue(text.undoManager?.canUndo == true)
    text.undoManager?.undo()
    XCTAssertEqual(workspace.fileText, "one two")

    text.setSelectedRange(NSRange(location: 4, length: 3))
    workspace.selectionEdit.selectionChanged(in: text)
    workspace.selectionEdit.open(path: "Edit.swift", source: workspace.fileText)
    workspace.selectionEdit.instruction = "uppercase"
    workspace.selectionEdit.generate { request in
      try request.proposal(from: "TWO")
    }
    for _ in 0..<20 where workspace.selectionEdit.proposal == nil { await Task.yield() }
    text.setSelectedRange(NSRange(location: 0, length: 3))
    workspace.selectionEdit.selectionChanged(in: text)
    XCTAssertFalse(workspace.selectionEdit.accept(path: workspace.selectedFile, source: workspace.fileText),
      "A stale selection must not apply an old proposal")
    XCTAssertEqual(workspace.fileText, "one two")
  }
  func testNativeFileEditorUpdatesWorkspaceDraft() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "original".write(to: root.appendingPathComponent("Edit.swift"), atomically: true, encoding: .utf8)
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"))
    let workspace = DeveloperWorkspace()
    workspace.root = root
    await workspace.openFile("Edit.swift")
    let window = FilePreviewTestWindow(contentRect: .init(x: 0, y: 0, width: 500, height: 350),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: FileSourcePreview(store: store, workspace: workspace))
    window.contentView = host
    host.frame.size = .init(width: 500, height: 350)
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    func preview(_ view: NSView) -> FilePreviewTextView? {
      if let text = view as? FilePreviewTextView { return text }
      return view.subviews.compactMap(preview).first
    }
    let text = try XCTUnwrap(preview(host))
    XCTAssertTrue(text.isEditable)
    text.insertText("updated", replacementRange: NSRange(location: 0, length: 8))
    XCTAssertEqual(workspace.fileText, "updated")
    XCTAssertTrue(workspace.selectedFileEditor?.hasUnsavedChanges == true)
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Edit.swift")), "original")
    XCTAssertTrue(text.undoManager?.canUndo == true)
    text.undoManager?.undo()
    XCTAssertEqual(workspace.fileText, "original")
    text.setSelectedRange(NSRange(location: 1, length: 3))
    try "external content".write(to: root.appendingPathComponent("Edit.swift"),
      atomically: true, encoding: .utf8)
    for _ in 0..<50 {
      if workspace.fileText == "external content" { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    host.layoutSubtreeIfNeeded()
    XCTAssertEqual(text.string, "external content")
    XCTAssertEqual(text.selectedRange(), NSRange(location: 1, length: 3))
  }

  func testFileFindReplacesThroughNativeEditorAndKeepsUndo() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "one two one".write(to: root.appendingPathComponent("Find.txt"), atomically: true, encoding: .utf8)
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"))
    let workspace = DeveloperWorkspace()
    workspace.root = root
    await workspace.openFile("Find.txt")
    let window = FilePreviewTestWindow(contentRect: .init(x: 0, y: 0, width: 500, height: 350),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: FileSourcePreview(store: store, workspace: workspace))
    window.contentView = host
    host.frame.size = .init(width: 500, height: 350)
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    func preview(_ view: NSView) -> FilePreviewTextView? {
      if let text = view as? FilePreviewTextView { return text }
      return view.subviews.compactMap(preview).first
    }
    let text = try XCTUnwrap(preview(host))
    let finder = workspace.fileFind
    finder.query = "one"
    finder.replacement = "three"
    finder.open(editor: text, replacing: true, source: text.string)
    for _ in 0..<30 {
      if finder.matches.count == 2 { break }
      try await Task.sleep(for: .milliseconds(30))
    }
    XCTAssertEqual(finder.matches.count, 2)
    finder.replaceCurrent()
    XCTAssertEqual(text.string, "three two one")
    XCTAssertEqual(workspace.fileText, "three two one")
    XCTAssertTrue(text.undoManager?.canUndo == true)
    text.undoManager?.undo()
    XCTAssertEqual(workspace.fileText, "one two one")
    for _ in 0..<30 {
      if finder.matches.count == 2 { break }
      try await Task.sleep(for: .milliseconds(30))
    }
    finder.replaceAll()
    XCTAssertEqual(text.string, "three two three")
    XCTAssertEqual(workspace.fileText, "three two three")
    text.undoManager?.undo()
    XCTAssertEqual(workspace.fileText, "one two one")
  }

  func testNativeSourceCommandsUpdateDraftAndPreserveUndo() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "one\ntwo".write(to: root.appendingPathComponent("Commands.swift"), atomically: true, encoding: .utf8)
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"))
    let workspace = DeveloperWorkspace()
    workspace.root = root
    await workspace.openFile("Commands.swift")
    let window = FilePreviewTestWindow(contentRect: .init(x: 0, y: 0, width: 500, height: 350),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: FileSourcePreview(store: store, workspace: workspace))
    window.contentView = host
    host.frame.size = .init(width: 500, height: 350)
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    func preview(_ view: NSView) -> FilePreviewTextView? {
      if let text = view as? FilePreviewTextView { return text }
      return view.subviews.compactMap(preview).first
    }
    let text = try XCTUnwrap(preview(host))
    text.setSelectedRange(NSRange(location: 0, length: 0))
    XCTAssertTrue(text.performSourceCommand(.toggleLineComment))
    XCTAssertEqual(workspace.fileText, "// one\ntwo")
    XCTAssertTrue(workspace.selectedFileEditor?.hasUnsavedChanges == true)
    XCTAssertTrue(text.undoManager?.canUndo == true)
    text.undoManager?.undo()
    XCTAssertEqual(text.string, "one\ntwo")
    XCTAssertEqual(workspace.fileText, "one\ntwo")
    text.setSelectedRange(NSRange(location: 1, length: 0))
    XCTAssertTrue(text.performSourceCommand(.moveDown))
    XCTAssertEqual(workspace.fileText, "two\none")
    text.undoManager?.undo()
    XCTAssertEqual(workspace.fileText, "one\ntwo")
  }

  func testFocusRequestWaitsForFileLoadAndDoesNotAffectMainWorkspace() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    let workspace = DeveloperWorkspace()
    workspace.root = root
    workspace.selectedFile = "File.swift"
    workspace.openFiles = ["File.swift"]
    workspace.fileLoading = true
    let mainFocus = store.workspace.fileFocusRequest
    let window = FilePreviewTestWindow(contentRect: .init(x: 0, y: 0, width: 500, height: 350),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: FileSourcePreview(store: store, workspace: workspace))
    window.contentView = host
    host.frame.size = .init(width: 500, height: 350)
    func settle() async throws {
      try await Task.sleep(for: .milliseconds(100))
      host.layoutSubtreeIfNeeded()
    }
    func preview(_ view: NSView) -> FilePreviewTextView? {
      if let text = view as? FilePreviewTextView { return text }
      return view.subviews.compactMap(preview).first
    }
    try await settle()
    let text = try XCTUnwrap(preview(host))
    // Set a distinct responder after initial mounting, then request focus while loading.
    window.makeFirstResponder(nil)
    workspace.fileFocusRequest = UUID()
    try await settle()
    XCTAssertFalse(window.firstResponder === text)
    workspace.fileText = "let loaded = true"
    workspace.fileLoading = false
    try await settle()
    XCTAssertTrue(window.firstResponder === text)
    XCTAssertEqual(text.string, "let loaded = true")
    XCTAssertEqual(store.workspace.fileFocusRequest, mainFocus)
    XCTAssertNil(store.workspace.selectedFile)
    window.acceptsFocus = false
    window.makeFirstResponder(nil)
    workspace.fileFocusRequest = UUID()
    try await settle()
    XCTAssertFalse(window.firstResponder === text, "An inactive window must not acquire file focus")
  }

  func testUnmountAndRemountRestoreSelectionAndScrollWithoutReplayingOldLineJump() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = WorkspaceStore(dataRoot: root)
    let workspace = DeveloperWorkspace()
    workspace.root = root
    workspace.selectedFile = "Long.swift"
    workspace.openFiles = ["Long.swift"]
    workspace.fileText = (1...200).map { "let row\($0) = \($0)" }.joined(separator: "\n")
    workspace.fileLineRange = NSRange(location: 0, length: 3)
    let window = FilePreviewTestWindow(contentRect: .init(x: 0, y: 0, width: 500, height: 350),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: AnyView(FileSourcePreview(store: store, workspace: workspace)))
    window.contentView = host
    func settle() async throws {
      try await Task.sleep(for: .milliseconds(100))
      host.layoutSubtreeIfNeeded()
    }
    func preview(_ view: NSView) -> FilePreviewTextView? {
      if let text = view as? FilePreviewTextView { return text }
      return view.subviews.compactMap(preview).first
    }
    try await settle()
    let original = try XCTUnwrap(preview(host))
    let selected = NSRange(location: 300, length: 12)
    original.setSelectedRange(selected)
    let scroll = try XCTUnwrap(original.enclosingScrollView)
    original.layoutManager?.ensureLayout(for: original.textContainer!)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 250))
    scroll.reflectScrolledClipView(scroll.contentView)
    let origin = scroll.contentView.bounds.origin
    XCTAssertGreaterThan(origin.y, 0)
    host.rootView = AnyView(EmptyView())
    try await settle()
    let saved = try XCTUnwrap(workspace.filePreviewPositions[root.path + "/Long.swift"])
    XCTAssertEqual(saved.selection, selected)
    XCTAssertEqual(saved.origin, origin)
    host.rootView = AnyView(FileSourcePreview(store: store, workspace: workspace))
    try await settle()
    let restored = try XCTUnwrap(preview(host))
    XCTAssertFalse(restored === original)
    XCTAssertEqual(restored.selectedRange(), selected)
    XCTAssertEqual(restored.enclosingScrollView?.contentView.bounds.origin.y ?? -1, origin.y, accuracy: 1)
    workspace.setProject(nil)
    XCTAssertTrue(workspace.filePreviewPositions.isEmpty)
  }

  func testDismantleDuringLoadingDoesNotOverwriteSavedPosition() {
    let workspace = DeveloperWorkspace()
    workspace.root = URL(fileURLWithPath: "/tmp")
    workspace.openFiles = ["File.swift"]
    let key = "/tmp/File.swift"
    let saved = FilePreviewPosition(selection: NSRange(location: 42, length: 8), origin: NSPoint(x: 0, y: 120))
    workspace.filePreviewPositions[key] = saved
    let coordinator = FileSourcePreview.Coordinator()
    coordinator.workspace = workspace
    coordinator.identity = key
    coordinator.wasLoading = true
    let scroll = NSScrollView()
    scroll.documentView = NSTextView()
    FileSourcePreview.dismantleNSView(scroll, coordinator: coordinator)
    XCTAssertEqual(workspace.filePreviewPositions[key]?.selection, saved.selection)
    XCTAssertEqual(workspace.filePreviewPositions[key]?.origin, saved.origin)
  }

  func testClosingLastFileDropsItsPositionBeforePreviewUnmounts() {
    let workspace = DeveloperWorkspace()
    workspace.root = URL(fileURLWithPath: "/tmp")
    workspace.selectedFile = "File.swift"
    workspace.openFiles = ["File.swift"]
    workspace.filePreviewPositions["/tmp/File.swift"] = FilePreviewPosition(
      selection: NSRange(location: 42, length: 8), origin: NSPoint(x: 0, y: 120))
    workspace.closeFile("File.swift")
    XCTAssertTrue(workspace.filePreviewPositions.isEmpty)
    let coordinator = FileSourcePreview.Coordinator()
    coordinator.workspace = workspace
    coordinator.identity = "/tmp/File.swift"
    let scroll = NSScrollView()
    scroll.documentView = NSTextView()
    FileSourcePreview.dismantleNSView(scroll, coordinator: coordinator)
    XCTAssertTrue(workspace.filePreviewPositions.isEmpty)
  }
}

// XCTest is not the foreground GUI app. Control window eligibility while exercising
// the real hosting view, asynchronous load and AppKit responder chain.
private final class FilePreviewTestWindow: NSWindow {
  var acceptsFocus = true
  override var isKeyWindow: Bool { acceptsFocus }
}
