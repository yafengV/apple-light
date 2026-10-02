import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class PullRequestCodeHeaderTests: XCTestCase {
  private func file(_ path: String, old: String? = nil, kind: GitHubPRCodeFile.Kind = .modified, lines: Int = 3) -> GitHubPRCodeFile {
    let code = (1...lines).map { "+let value\($0) = \"" + String(repeating: "text ", count: 60) + "\"" }.joined(separator: "\n")
    return .init(path: path, oldPath: old ?? path, patch: "@@ -0,0 +1,\(lines) @@\n" + code, kind: kind, binary: false)
  }
  private func fixture() async throws -> GitHubPRCodeState {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pr-headers-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    _ = try await GitReviewService.checked(["init", "-q", "-b", "unrelated-local-branch"], at: root)
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/github_cli.py")
    let executable = root.appendingPathComponent(".git/gh-fixture")
    try FileManager.default.copyItem(at: source, to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let head = String(repeating: "a", count: 40)
    let pr = GitHubPullRequest(number: 42, url: "https://github.com/sample/project/pull/42", title: "Feature",
      isDraft: false, headRefName: "feature", baseRefName: "main", isCrossRepository: false)
    let paths = ["Sources/Long.swift", "Sources/Other.swift"]
    let patch = paths.enumerated().map { index, path in
      "diff --git a/\(path) b/\(path)\n--- a/\(path)\n+++ b/\(path)\n" + file(path, lines: index == 0 ? 120 : 60).patch + "\n"
    }.joined()
    let item = try JSONSerialization.jsonObject(with: JSONEncoder().encode(pr))
    try JSONSerialization.data(withJSONObject: ["head": head, "pullRequests": [item], "codeChangedFiles": 2, "prDiff": patch])
      .write(to: root.appendingPathComponent(".git/github-fixture.json"))
    let state = GitHubPRCodeState(service: .init(executable: executable))
    await state.load(.init(taskID: "task", root: root, pullRequest: pr, head: head), valid: { true })
    XCTAssertEqual(state.files.count, 2); return state
  }
  private func window<V: View>(_ content: V, width: CGFloat = 800) -> (NSWindow, NSHostingView<V>) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 560),
      styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: content); window.contentView = host
    return (window, host)
  }
  private func settle(_ host: NSView) async throws {
    try await Task.sleep(for: .milliseconds(200)); host.layoutSubtreeIfNeeded()
  }
  private func scrolls(_ view: NSView) -> [NSScrollView] {
    ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrolls)
  }
  private func buttons(_ node: NSView) -> [PullRequestCodeHeaderButtonView] {
    ((node as? PullRequestCodeHeaderButtonView).map { [$0] } ?? []) + node.subviews.flatMap(buttons)
  }
  private func gutters(_ node: NSView) -> [PullRequestCodeGutterView] {
    ((node as? PullRequestCodeGutterView).map { [$0] } ?? []) + node.subviews.flatMap(gutters)
  }
  private func header(_ host: NSView, path: String) throws -> PullRequestCodeHeaderButtonView {
    return try XCTUnwrap(buttons(host).first {
      $0.identifier?.rawValue == "pull-request-code-header-" + path
    })
  }
  private func frame(_ node: NSView) -> NSRect {
    node.convert(node.bounds, to: nil)
  }
  private func press(_ node: PullRequestCodeHeaderButtonView) -> Bool {
    node.accessibilityPerformPress()
  }

  func testRelativeCopyAndRenameHeaderNeverCopyOldNameOrLocalAbsolutePath() {
    let value = file("Sources/新文件.swift", old: "Old/旧.swift", kind: .renamed)
    XCTAssertEqual(value.headerDescription, "Old/旧.swift → Sources/新文件.swift")
    XCTAssertEqual(value.headerFilename, "旧.swift → 新文件.swift")
    let board = NSPasteboard.withUniqueName(); defer { board.clearContents() }
    XCTAssertTrue(PullRequestCodeClipboard.copy(value, to: board))
    XCTAssertEqual(board.string(forType: .string), "Sources/新文件.swift")
    XCTAssertEqual(file("new.swift", old: "old.swift", kind: .copied).headerDescription, "new.swift")
    XCTAssertEqual(file("old.swift", kind: .deleted).headerDescription, "old.swift")
    XCTAssertEqual(file("dir\\file.swift").headerRelativePath, "dir/file.swift")
  }
  func testOptionToggleUsesClickedFileStateAndKeepsSelectionAndWindowScope() async throws {
    let state = try await fixture(), other = try await fixture()
    state.select(state.files[1].path); state.toggle(state.files[0].path)
    XCTAssertTrue(state.groupExpanded); XCTAssertFalse(state.allCollapsed)
    state.toggle(state.files[0].path, all: true)
    XCTAssertTrue(state.collapsed.isEmpty); XCTAssertTrue(state.groupExpanded)
    state.toggle(state.files[1].path, all: true)
    XCTAssertTrue(state.allCollapsed); XCTAssertFalse(state.groupExpanded)
    XCTAssertEqual(state.selectedPath, state.files[1].path); XCTAssertTrue(other.collapsed.isEmpty)
    state.toggle("missing.swift", all: true); XCTAssertTrue(state.allCollapsed)
  }
  func testHiddenNativeHeaderPressDoesNotRequireCodeBodyAndStaysBounded() async throws {
    let state = try await fixture()
    let value = state.files[0]
    let (window, host) = window(PullRequestCodeFileHeader(file: value, state: state).frame(width: 350), width: 350)
    defer { window.close() }; try await settle(host)
    let button = try header(host, path: value.path)
    XCTAssertGreaterThan(button.bounds.width, 250)
    XCTAssertTrue(press(button)); try await settle(host)
    XCTAssertTrue(state.collapsed.contains(value.path))
    XCTAssertTrue(press(button)); try await settle(host)
    XCTAssertFalse(state.collapsed.contains(value.path)); XCTAssertFalse(window.isVisible)
    XCTAssertLessThanOrEqual(host.fittingSize.width, 350)
  }
  func testHiddenWholeCodePagePinsHeaderAndHorizontalFileScrollDoesNotMoveIt() async throws {
    let state = try await fixture()
    let (window, host) = window(TaskPullRequestCodeView(state: state, discussion: .init(), enabled: false,
      writable: false, mentionRequest: nil, open: { _ in }, submit: { _, _ in }, retry: {}, retryComments: {}))
    defer { window.close() }; try await settle(host)
    let all = scrolls(host)
    let vertical = try XCTUnwrap(all.first { $0.hasVerticalScroller && ($0.documentView?.bounds.height ?? 0) > $0.contentSize.height + 100 })
    let initial = try frame(header(host, path: state.files[0].path))
    vertical.contentView.scroll(to: NSPoint(x: 0, y: 450)); vertical.reflectScrolledClipView(vertical.contentView)
    try await settle(host)
    let pinned = try frame(header(host, path: state.files[0].path))
    XCTAssertLessThan(abs(pinned.minY - initial.minY), 35)
    XCTAssertGreaterThan(vertical.contentView.bounds.origin.y, 400)
    let horizontal = try XCTUnwrap(scrolls(host).first { $0.hasHorizontalScroller && ($0.documentView?.bounds.width ?? 0) > $0.contentSize.width + 100 })
    horizontal.contentView.scroll(to: NSPoint(x: 250, y: 0)); horizontal.reflectScrolledClipView(horizontal.contentView)
    try await settle(host)
    XCTAssertGreaterThan(horizontal.contentView.bounds.origin.x, 100)
    let after = try frame(header(host, path: state.files[0].path))
    XCTAssertEqual(after.minX, pinned.minX, accuracy: 1); XCTAssertEqual(after.minY, pinned.minY, accuracy: 1)
    XCTAssertFalse(window.isVisible)
  }
  func testNativeReturnSpaceOptionAndCopyKeepIndependentActionsAndCleanup() async throws {
    let state = try await fixture(), path = state.files[0].path
    var copies: [String] = []
    let (window, host) = window(PullRequestCodeFileHeader(file: state.files[0], state: state,
      copy: { copies.append($0.headerRelativePath); return true }).frame(width: 700))
    defer { window.close() }; try await settle(host)
    let title = try header(host, path: path)
    func key(_ code: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
      try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: code == 49 ? " " : "\r",
        charactersIgnoringModifiers: code == 49 ? " " : "\r", isARepeat: false, keyCode: code))
    }
    title.keyDown(with: try key(36, flags: .option)); XCTAssertTrue(state.allCollapsed)
    title.keyDown(with: try key(49, flags: .option)); XCTAssertTrue(state.collapsed.isEmpty)
    title.keyDown(with: try key(49)); XCTAssertEqual(state.collapsed, [path])
    let copy = try XCTUnwrap(buttons(host).first { $0.identifier?.rawValue == "pull-request-code-copy-" + path })
    _ = window.makeFirstResponder(copy); try await settle(host)
    copy.keyDown(with: try key(36)); XCTAssertEqual(copies, [path]); XCTAssertEqual(state.collapsed, [path])
    XCTAssertTrue(copy.accessibilityPerformPress()); XCTAssertEqual(copies, [path, path]); XCTAssertEqual(state.collapsed, [path])
    copy.isEnabled = false; XCTAssertFalse(copy.accessibilityPerformPress()); XCTAssertEqual(copies.count, 2)
    copy.keyDown(with: try key(36)); XCTAssertEqual(copies.count, 2)
    copy.isEnabled = true; host.rootView = PullRequestCodeFileHeader(file: state.files[1], state: state,
      copy: { copies.append($0.headerRelativePath); return true }).frame(width: 700)
    try await settle(host)
    // SwiftUI may reuse the NSButton; it must now point at the new file, never
    // keep the old action. Removed controls explicitly release their callbacks.
    let current = try XCTUnwrap(buttons(host).first { $0.identifier?.rawValue == "pull-request-code-copy-" + state.files[1].path })
    XCTAssertTrue(current.accessibilityPerformPress()); XCTAssertEqual(copies.last, state.files[1].path)
    XCTAssertFalse(window.isVisible)
  }

  func testHiddenNarrowRenameHeaderKeepsFullAccessiblePathAndIndependentCopy() async throws {
    let state = try await fixture()
    let value = file("Sources/VeryLongDirectory/Nested/NewFile.swift",
      old: "Old/VeryLongDirectory/Nested/OldFile.swift", kind: .renamed)
    var copied: String?
    let (window, host) = window(PullRequestCodeFileHeader(file: value, state: state,
      copy: { copied = $0.headerRelativePath; return true }).frame(width: 330), width: 330)
    defer { window.close() }; try await settle(host)
    let title = try header(host, path: value.path)
    XCTAssertEqual(title.accessibilityLabel(), value.headerDescription)
    XCTAssertEqual(title.toolTip, value.headerDescription)
    XCTAssertLessThanOrEqual(host.fittingSize.width, 330)
    XCTAssertGreaterThan(title.bounds.width, 200)
    let copy = try XCTUnwrap(buttons(host).first { $0.identifier?.rawValue == "pull-request-code-copy-" + value.path })
    XCTAssertTrue(copy.accessibilityPerformPress()); XCTAssertEqual(copied, value.path)
    XCTAssertTrue(state.collapsed.isEmpty); XCTAssertFalse(window.isVisible)
  }

  func testHiddenNarrowWrappedUnifiedAndSplitPagesDoNotOverflowHorizontally() async throws {
    let state = try await fixture(); state.wrap = true
    let (window, host) = window(TaskPullRequestCodeView(state: state, discussion: .init(), enabled: false,
      writable: false, mentionRequest: nil, open: { _ in }, submit: { _, _ in }, retry: {}, retryComments: {}), width: 470)
    defer { window.close() }; try await settle(host)
    for split in [false, true] {
      state.split = split; try await settle(host)
      let vertical = try XCTUnwrap(scrolls(host).first { $0.hasVerticalScroller })
      XCTAssertLessThanOrEqual(vertical.documentView?.bounds.width ?? .infinity, vertical.contentSize.width + 1)
      XCTAssertFalse(scrolls(host).contains { $0.hasHorizontalScroller })
      let title = try frame(header(host, path: state.files[0].path))
      XCTAssertGreaterThanOrEqual(title.minX, 0); XCTAssertLessThanOrEqual(title.maxX, 470)
      XCTAssertGreaterThan(vertical.documentView?.bounds.height ?? 0, vertical.contentSize.height)
    }
    state.wrap = false; try await settle(host)
    XCTAssertTrue(scrolls(host).contains { $0.hasHorizontalScroller })
    XCTAssertFalse(window.isVisible)
  }

  func testHiddenPRToolbarFitsBelowBranchLabelBreakpoint() async throws {
    let state = try await fixture(); state.wrap = true
    let (window, host) = window(TaskPullRequestCodeView(state: state, discussion: .init(), enabled: false,
      writable: false, mentionRequest: nil, open: { _ in }, submit: { _, _ in }, retry: {}, retryComments: {}),
      width: 360)
    defer { window.close() }; try await settle(host)
    XCTAssertLessThanOrEqual(host.fittingSize.width, 360)
    XCTAssertFalse(scrolls(host).contains { $0.hasHorizontalScroller })
    let title = try frame(header(host, path: state.files[0].path))
    XCTAssertGreaterThanOrEqual(title.minX, 0)
    XCTAssertLessThanOrEqual(title.maxX, 360)
    XCTAssertFalse(window.isVisible)
  }

  func testHiddenFileAndCommentLineNavigationSurvivesStickySectionsAndModeChanges() async throws {
    let state = try await fixture()
    let (window, host) = window(TaskPullRequestCodeView(state: state, discussion: .init(), enabled: false,
      writable: false, mentionRequest: nil, open: { _ in }, submit: { _, _ in }, retry: {}, retryComments: {}))
    defer { window.close() }; try await settle(host)
    for split in [false, true] {
      state.split = split
      state.open(.init(path: state.files[0].path, line: 80, side: .right, startLine: nil, startSide: nil))
      try await Task.sleep(for: .milliseconds(400)); host.layoutSubtreeIfNeeded()
      let vertical = try XCTUnwrap(scrolls(host).first { $0.hasVerticalScroller })
      let viewport = frame(vertical.contentView)
      let row = try XCTUnwrap(gutters(host).first { $0.path == state.files[0].path && $0.point.side == .right && $0.point.line == 80 })
      XCTAssertTrue(viewport.intersects(frame(row)), "Comment line must be visible after its file is materialized")
      XCTAssertGreaterThan(vertical.contentView.bounds.origin.y, 500)
      state.select(state.files[1].path)
      try await Task.sleep(for: .milliseconds(400)); host.layoutSubtreeIfNeeded()
      let next = try frame(header(host, path: state.files[1].path))
      XCTAssertTrue(frame(vertical.contentView).intersects(next), "Selected file header must be visible")
      XCTAssertNil(state.position)
    }
    XCTAssertFalse(window.isVisible)
  }

  func testHiddenRepeatedLineNavigationPreservesHorizontalOffsetAndCancelsRemovedTarget() async throws {
    let state = try await fixture(), path = state.files[0].path
    let (window, host) = window(TaskPullRequestCodeView(state: state, discussion: .init(), enabled: false,
      writable: false, mentionRequest: nil, open: { _ in }, submit: { _, _ in }, retry: {}, retryComments: {}))
    defer { window.close() }; try await settle(host)
    let horizontal = try XCTUnwrap(scrolls(host).first { $0.hasHorizontalScroller })
    horizontal.contentView.scroll(to: NSPoint(x: 250, y: 0)); horizontal.reflectScrolledClipView(horizontal.contentView)
    func jump(_ line: Int) { state.open(.init(path: path, line: line, side: .right, startLine: nil, startSide: nil)) }
    jump(20); try await Task.sleep(for: .milliseconds(20)); jump(80)
    try await Task.sleep(for: .milliseconds(350)); host.layoutSubtreeIfNeeded()
    let vertical = try XCTUnwrap(scrolls(host).first { $0.hasVerticalScroller })
    let viewport = frame(vertical.contentView)
    let row = try XCTUnwrap(gutters(host).first { $0.path == path && $0.point.side == .right && $0.point.line == 80 })
    XCTAssertGreaterThanOrEqual(frame(row).midY, viewport.minY)
    XCTAssertLessThanOrEqual(frame(row).midY, viewport.maxY)
    XCTAssertEqual(horizontal.contentView.bounds.origin.x, 250, accuracy: 1)
    jump(10); try await Task.sleep(for: .milliseconds(20))
    window.contentView = nil
    let offset = vertical.contentView.bounds.origin.y
    try await Task.sleep(for: .milliseconds(250))
    XCTAssertEqual(vertical.contentView.bounds.origin.y, offset, accuracy: 1)
    XCTAssertNil(row.window); XCTAssertFalse(window.isVisible)
  }
}
