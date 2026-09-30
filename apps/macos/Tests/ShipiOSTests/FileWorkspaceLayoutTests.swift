import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class FileWorkspaceLayoutTests: XCTestCase {
  func testFileTreeContextActionAddsFileToOwningTaskDraft() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let primary = root.appendingPathComponent("Primary")
    let attached = root.appendingPathComponent("Attached")
    try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: attached, withIntermediateDirectories: true)
    try "source text".write(to: primary.appendingPathComponent("Edit.swift"), atomically: true, encoding: .utf8)
    try "attached text".write(to: attached.appendingPathComponent("Note.txt"), atomically: true, encoding: .utf8)
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"))
    await store.restore()
    let workspace = DeveloperWorkspace()
    workspace.root = primary
    workspace.setAdditionalFileRoots([attached])
    let view = FileWorkspaceView(store: store, workspace: workspace, taskID: "owner-task")

    await view.addFileToChat("Edit.swift")
    let attachment = try XCTUnwrap(store.library.draftFiles["owner-task"]?.first)
    XCTAssertEqual(attachment.name, "Edit.swift")
    XCTAssertTrue(store.draftFiles.isEmpty)
    XCTAssertEqual(try FileAttachmentStorage.text(attachment, root: store.dataRoot), "source text")

    await view.addFileToChat(attached.appendingPathComponent("Note.txt").path)
    let attachedFile = try XCTUnwrap(store.library.draftFiles["owner-task"]?.last)
    XCTAssertEqual(try FileAttachmentStorage.text(attachedFile, root: store.dataRoot), "attached text")

    await view.addFileToChat("../outside.txt")
    XCTAssertEqual(store.library.draftFiles["owner-task"]?.count, 2)
    XCTAssertNotNil(store.error)
    await store.shutdown()
  }

  func testFileTreeCanHideWithoutLosingOpenEditor() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "let value = 42\n".write(to: root.appendingPathComponent("Edit.swift"), atomically: true, encoding: .utf8)
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"))
    let workspace = DeveloperWorkspace()
    workspace.root = root
    await workspace.openFile("Edit.swift")
    await workspace.refreshFiles()

    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 850, height: 600),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: FileWorkspaceView(store: store, workspace: workspace))
    window.contentView = host
    host.frame.size = .init(width: 850, height: 600)

    func editorFrame() async throws -> CGRect {
      try await Task.sleep(for: .milliseconds(120))
      host.layoutSubtreeIfNeeded()
      func find(_ view: NSView) -> FilePreviewTextView? {
        if let editor = view as? FilePreviewTextView { return editor }
        return view.subviews.compactMap(find).first
      }
      let editor = try XCTUnwrap(find(host))
      XCTAssertEqual(editor.string, "let value = 42\n")
      return editor.convert(editor.bounds, to: host)
    }

    let withTree = try await editorFrame()
    XCTAssertLessThan(withTree.minX, 80)
    XCTAssertLessThan(withTree.maxX, 710, "The visible tree should occupy the trailing side")
    workspace.fileTreeVisible = false
    let withoutTree = try await editorFrame()
    XCTAssertLessThan(withoutTree.minX, 80)
    XCTAssertGreaterThan(withoutTree.maxX, withTree.maxX + 150)
    workspace.fileTreeVisible = true
    let restoredTree = try await editorFrame()
    XCTAssertLessThan(restoredTree.maxX, 710)
    window.setContentSize(.init(width: 500, height: 600))
    host.frame.size = .init(width: 500, height: 600)
    let compactEditor = try await editorFrame()
    XCTAssertLessThan(compactEditor.minX, 80)
    XCTAssertGreaterThan(compactEditor.maxX, 450, "The editor should fill a narrow file panel")
    XCTAssertEqual(workspace.selectedFile, "Edit.swift")
  }
}
