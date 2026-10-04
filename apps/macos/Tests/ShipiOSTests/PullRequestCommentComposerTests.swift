import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class PullRequestCommentComposerTests: XCTestCase {
  private let request = GitHubPullRequest(number: 42, url: "https://github.com/sample/project/pull/42",
    title: "Feature", isDraft: false, headRefName: "feature", baseRefName: "main", isCrossRepository: false)
  private final class TestWindow: NSWindow { override var isKeyWindow: Bool { true } }
  private struct SurfaceAnchor: NSViewRepresentable {
    let capture: (NSView) -> Void
    func makeNSView(context: Context) -> NSView { let view = NSView(); capture(view); return view }
    func updateNSView(_ view: NSView, context: Context) {}
  }
  private final class Scope: NSView, WindowModalScope {
    var modalRoot: NSView { self }
    var modalScopeActive = true
    var blocksWorkspaceCommands: Bool { true }
  }
  private func tick() async {
    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
  }
  private func editor(in view: NSView) -> PullRequestTextEditor.TextView? {
    if let text = view as? PullRequestTextEditor.TextView { return text }
    return view.subviews.lazy.compactMap { self.editor(in: $0) }.first
  }
  private func host<V: View>(_ view: V, width: CGFloat = 420) async throws
    -> (NSWindow, NSView, PullRequestTextEditor.TextView) {
    _ = NSApplication.shared
    let window = TestWindow(contentRect: .init(x: 0, y: 0, width: width, height: 400),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
    let root = NSHostingView(rootView: VStack(alignment: .leading, spacing: 0) {
      view; Spacer(minLength: 0)
    }.frame(width: width, height: 400, alignment: .topLeading))
    window.contentView = root
    addTeardownBlock { @MainActor in window.contentView = nil; window.close() }
    for _ in 0..<4 { root.layoutSubtreeIfNeeded(); await tick() }
    return (window, root, try XCTUnwrap(editor(in: root)))
  }
  private func key(_ code: UInt16, _ window: NSWindow, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: code == 36 ? "\r" : "",
      charactersIgnoringModifiers: code == 36 ? "\r" : "", isARepeat: false, keyCode: code))
  }
  private func reference() throws -> [String: Any] {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/pr_comment_composer_reference.json")
    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
  }
  private func render(_ root: NSView, _ name: String) throws {
    guard let directory = ProcessInfo.processInfo.environment["SHIPIOS_PR_COMPOSER_RENDER_DIR"] else { return }
    root.layoutSubtreeIfNeeded()
    let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
    root.cacheDisplay(in: root.bounds, to: bitmap)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to:
      URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
  }

  func testActualComponentFactsCoverSurfaceFocusSubmissionAndAvatarEncoding() throws {
    let f = try reference()
    XCTAssertEqual(f["version"] as? String, "26.930.21537")
    XCTAssertEqual(f["sha256"] as? String, "75f3614a2d5537a334dda26896e87ed89bf35e3bcb6698f93eeb00699d3a56c4")
    XCTAssertEqual(f["avatarSHA256"] as? String, "d48e88a03c1fbb283abb6344b90099a9e3a78af5bd087eda235db7981b2d1c28")
    let cases = try XCTUnwrap(f["cases"] as? [[String: Any]])
    XCTAssertEqual(cases.count, 6)
    for sample in cases {
      let name = try XCTUnwrap(sample["name"] as? String)
      let kind: PullRequestCommentComposerKind = sample["editing"] as? Bool == true ? .edit :
        (sample["reply"] as? Bool == true ? .reply(author: "author") : .comment)
      XCTAssertEqual(kind.inlineSurface, sample["surfaceVariant"] as? String == "inline")
      XCTAssertEqual(sample["autoFocus"] as? Bool, kind.inlineSurface)
      XCTAssertEqual(sample["textareaDisabled"] as? Bool, sample["pending"] as? Bool)
      XCTAssertEqual(sample["cancelPresent"] as? Bool, kind.inlineSurface)
      if name == "edit" { XCTAssertEqual(sample["submitted"] as? [String], ["  Raw\n "]) }
      if name == "comment" { XCTAssertEqual(sample["submitted"] as? [String], ["Comment"]) }
      if name == "reply" { XCTAssertEqual(sample["submitted"] as? [String], ["Reply"]) }
      if name == "empty" || name == "pending" { XCTAssertEqual(sample["submitted"] as? [String], []) }
      if name == "failure" { XCTAssertEqual(sample["bodyAfter"] as? String, "Retry"); XCTAssertEqual(sample["errorRole"] as? String, "alert") }
    }
    for sample in try XCTUnwrap(f["avatarCases"] as? [[String: Any]]) {
      let login = try XCTUnwrap(sample["login"] as? String)
      XCTAssertEqual(PullRequestCommentComposerKind.avatarURL(login)?.absoluteString, sample["url"] as? String)
    }
    XCTAssertNil(PullRequestCommentComposerKind.avatarURL(nil))
    XCTAssertEqual(PullRequestCommentComposerKind.reply(author: nil).placeholder, "回复 评论")
  }

  func testMountedModesExposePlaceholderLabelsPaddingAndFocus() async throws {
    for kind: PullRequestCommentComposerKind in [.comment, .edit, .reply(author: "reviewer")] {
      let token: UUID? = kind.inlineSurface ? UUID() : nil
      var surface: NSView?
      let (window, root, text) = try await host(TaskPullRequestCommentComposer(text: .constant(""),
        label: "提交", focus: token, enabled: true, busy: false,
        cancel: kind.inlineSurface ? {} : nil, kind: kind, submit: {})
        .background { SurfaceAnchor { surface = $0 } })
      XCTAssertEqual(text.placeholder, kind.placeholder); XCTAssertEqual(text.accessibilityLabel(), kind.accessibilityLabel)
      XCTAssertEqual(text.textContainerOrigin, .init(x: 0, y: 10)); XCTAssertEqual(text.textContainer?.lineFragmentPadding, 0)
      XCTAssertEqual(text.font?.pointSize, 16); XCTAssertEqual(text.defaultParagraphStyle?.minimumLineHeight, 28)
      let frame = root.convert(try XCTUnwrap(text.enclosingScrollView).bounds, from: text.enclosingScrollView)
      XCTAssertEqual(frame.minX, 12, accuracy: 1); XCTAssertEqual(frame.width, 396, accuracy: 1)
      XCTAssertEqual(frame.height, 38, accuracy: 1)
      XCTAssertEqual(try XCTUnwrap(surface).bounds.height, 74, accuracy: 1,
        "The composer itself must fit its text and 24-point avatar, rather than stretch to the maximum editor height")
      XCTAssertEqual(window.firstResponder === text, kind.inlineSurface)
      XCTAssertFalse(window.isVisible)
      try render(root, kind == .comment ? "empty" : kind == .edit ? "edit-empty" : "reply-empty")
    }
  }

  func testNativeReturnUndoAndMarkedTextUseRetainedDraftAndDoNotCancelOnEscape() async throws {
    var value = "", submissions = 0, cancels = 0
    let (window, _, text) = try await host(TaskPullRequestCommentComposer(
      text: Binding(get: { value }, set: { value = $0 }), label: "保存更改", focus: UUID(), enabled: true,
      busy: false, cancel: { cancels += 1 }, kind: .edit, submit: { submissions += 1 }))
    text.keyDown(with: try key(36, window, .command)); XCTAssertEqual(submissions, 0)
    text.insertText("First", replacementRange: .init(location: 0, length: 0)); text.breakUndoCoalescing()
    text.keyDown(with: try key(36, window)); XCTAssertEqual(value, "First\n")
    text.keyDown(with: try key(36, window, .control)); XCTAssertEqual(submissions, 1)
    text.keyDown(with: try key(53, window)); XCTAssertEqual(cancels, 0)
    await tick(); text.breakUndoCoalescing()
    text.insertText("Second", replacementRange: text.selectedRange()); text.breakUndoCoalescing()
    XCTAssertEqual(value, "First\nSecond"); text.undoManager?.undo(); XCTAssertEqual(value, "First\n")
    text.undoManager?.redo(); XCTAssertEqual(value, "First\nSecond")
    text.setMarkedText("拼音", selectedRange: .init(location: 2, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
    XCTAssertTrue(text.hasMarkedText()); text.keyDown(with: try key(36, window, .command))
    XCTAssertEqual(submissions, 1); text.unmarkText()
  }

  func testLongNarrowInputCapsWholeComposerRatherThanOnlyNativeTextView() async throws {
    var surface: NSView?
    let (_, root, text) = try await host(TaskPullRequestCommentComposer(text: .constant(
      Array(repeating: "A long line wraps in this narrow composer", count: 30).joined(separator: "\n")),
      label: "发表评论", focus: nil, enabled: true, busy: false, cancel: nil, submit: {})
      .background { SurfaceAnchor { surface = $0 } }, width: 240)
    XCTAssertEqual(try XCTUnwrap(text.enclosingScrollView).bounds.height, 192, accuracy: 1)
    XCTAssertEqual(try XCTUnwrap(surface).bounds.height, 228, accuracy: 1)
    XCTAssertEqual(text.textContainerOrigin.y, 10); try render(root, "long-narrow")
  }

  func testModalBlocksNativeEditingCallbacksAndMentionReplacementOnlyInOwningWindow() async throws {
    var value = "@re", submitted = 0, selections = 0
    let parent = PullRequestTextEditor(text: Binding(get: { value }, set: { value = $0 }), field: .body,
      focus: nil, submit: { submitted += 1 }, cancel: {}, selectionChanged: { _, _ in selections += 1 }, growsWithContent: true)
    let (window, root, text) = try await host(parent)
    let owner = try XCTUnwrap(text.delegate as? PullRequestTextEditor.Coordinator)
    let (_, _, other) = try await host(PullRequestTextEditor(text: .constant("other"), field: .body, focus: nil, submit: {}, cancel: {}))
    text.setSelectedRange(.init(location: 3, length: 0)); window.makeFirstResponder(text)
    let scope = Scope(frame: .init(x: 0, y: 0, width: 100, height: 100)); root.addSubview(scope)
    WindowModalInteraction.install(scope, in: window); selections = 0
    XCTAssertFalse(text.acceptsFirstResponder); XCTAssertFalse(text.canBecomeKeyView); XCTAssertTrue(other.acceptsFirstResponder)
    XCTAssertTrue(text.isEditable, "A modal must retain the enabled appearance of its background editor")
    text.keyDown(with: try key(36, window, .command)); XCTAssertEqual(submitted, 0)
    text.insertText("blocked", replacementRange: text.selectedRange()); XCTAssertEqual(text.string, "@re")
    let replacement = PullRequestTextReplacement(expectedText: "@re", selection: .init(location: 3, length: 0),
      range: .init(location: 0, length: 3), text: "@reviewer ")
    XCTAssertFalse(text.apply(replacement)); XCTAssertEqual(text.string, "@re")
    text.string = "late callback"; owner.textDidChange(Notification(name: NSText.didChangeNotification, object: text))
    owner.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: text))
    XCTAssertEqual(value, "@re"); XCTAssertEqual(selections, 0)
    WindowModalInteraction.remove(scope, from: window); scope.removeFromSuperview(); text.string = value
    text.setSelectedRange(replacement.selection); XCTAssertTrue(text.apply(replacement)); XCTAssertEqual(value, "@reviewer ")
    text.keyDown(with: try key(36, window, .command)); XCTAssertEqual(submitted, 1)
  }

  func testBlockedDeferredFocusCanRetryAfterModalAndUnmountCannotStealFocus() async throws {
    let (window, root, text) = try await host(PullRequestTextEditor(text: .constant("draft"), field: .body,
      focus: nil, submit: {}, cancel: {}))
    let owner = try XCTUnwrap(text.delegate as? PullRequestTextEditor.Coordinator)
    let scope = Scope(frame: .init(x: 0, y: 0, width: 100, height: 100)); root.addSubview(scope)
    let inside = NSTextView(frame: scope.bounds); scope.addSubview(inside)
    let token = UUID(); owner.updateFocus(text, token: token, enabled: true)
    WindowModalInteraction.install(scope, in: window); window.makeFirstResponder(inside); await tick()
    XCTAssertTrue(window.firstResponder === inside)
    WindowModalInteraction.remove(scope, from: window); scope.removeFromSuperview()
    owner.updateFocus(text, token: token, enabled: true); await tick()
    XCTAssertTrue(window.firstResponder === text); XCTAssertEqual(text.selectedRange(), .init(location: 5, length: 0))
    let next = NSTextView(frame: .init(x: 0, y: 0, width: 100, height: 50)); root.addSubview(next); window.makeFirstResponder(next)
    owner.updateFocus(text, token: UUID(), enabled: true)
    PullRequestTextEditor.dismantleNSView(try XCTUnwrap(text.enclosingScrollView), coordinator: owner); await tick()
    XCTAssertTrue(window.firstResponder === next); XCTAssertFalse(text.isEditable); XCTAssertFalse(owner.active)
  }

  func testDeferredMentionDoesNotWriteThroughNewModal() async throws {
    var value = "@re"
    let (window, root, text) = try await host(PullRequestTextEditor(text: Binding(get: { value }, set: { value = $0 }),
      field: .body, focus: nil, submit: {}, cancel: {}))
    let owner = try XCTUnwrap(text.delegate as? PullRequestTextEditor.Coordinator)
    let replacement = PullRequestTextReplacement(expectedText: value, selection: .init(location: 3, length: 0),
      range: .init(location: 0, length: 3), text: "@reviewer ")
    text.setSelectedRange(replacement.selection); window.makeFirstResponder(text)
    owner.parent.replacement = replacement; owner.updateReplacement(text, replacement: replacement)
    let scope = Scope(frame: root.bounds); root.addSubview(scope); WindowModalInteraction.install(scope, in: window)
    await tick(); XCTAssertEqual(text.string, "@re"); XCTAssertEqual(value, "@re")
    WindowModalInteraction.remove(scope, from: window); scope.removeFromSuperview()
  }

  func testPendingAndReadOnlyEditorsRejectNativeInputAndKeyboardSubmission() async throws {
    for enabled in [false, true] {
      var value = "draft", calls = 0
      let (_, root, text) = try await host(TaskPullRequestCommentComposer(
        text: Binding(get: { value }, set: { value = $0 }), label: "发布回复", focus: UUID(),
        enabled: enabled, busy: enabled, cancel: {}, inputEnabled: false, kind: .reply(author: "author"), submit: { calls += 1 }))
      let window = try XCTUnwrap(text.window)
      XCTAssertFalse(text.isEditable); XCTAssertFalse(text.acceptsFirstResponder)
      text.keyDown(with: try key(36, window, .command)); text.insertText("bad", replacementRange: .init(location: 0, length: 0))
      XCTAssertEqual(value, "draft"); XCTAssertEqual(text.string, "draft"); XCTAssertEqual(calls, 0)
      try render(root, enabled ? "reply-pending" : "reply-readonly")
    }
  }

  private func fixture(_ extra: [String: Any] = [:]) async throws -> (URL, GitHubPRDiscussionState) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("comment-composer-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    _ = try await GitReviewService.checked(["init", "-q", "-b", "feature"], at: root)
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/github_cli.py")
    let executable = root.appendingPathComponent(".git/gh-fixture")
    try FileManager.default.copyItem(at: source, to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    var fields: [String: Any] = ["head": String(repeating: "a", count: 40), "viewer": "reviewer",
      "pullRequests": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))],
      "discussionTimeline": [["id": "one", "__typename": "IssueComment", "body": "Original",
        "createdAt": "2026-09-29T10:00:00Z", "author": ["login": "reviewer", "__typename": "User"], "viewerCanUpdate": true, "viewerCanDelete": true]]]
    extra.forEach { fields[$0.key] = $0.value }
    try JSONSerialization.data(withJSONObject: fields).write(to: root.appendingPathComponent(".git/github-fixture.json"))
    let state = GitHubPRDiscussionState(service: .init(executable: executable), coordinator: .init())
    await state.load(request, at: root, valid: { true }); XCTAssertNil(state.readError)
    addTeardownBlock { @MainActor in state.cancel() }
    return (root, state)
  }
  private func writes(_ root: URL) throws -> [[String: Any]] {
    let path = root.appendingPathComponent(".git/github-requests.jsonl")
    return try String(contentsOf: path, encoding: .utf8).split(separator: "\n").compactMap {
      let value = try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
      guard let input = value?["input"] as? [String: Any], (input["query"] as? String)?.contains("mutation ShipiOSPRDiscussionMutation") == true else { return nil }
      return (input["variables"] as? [String: Any])?["input"] as? [String: Any]
    }
  }
  private func content(_ state: GitHubPRDiscussionState, _ comment: GitHubPRComment, _ root: URL) -> some View {
    TaskPullRequestCommentContentView(comment: comment, state: state, enabled: true, writable: true,
      mentionRequest: nil, open: { _ in }, submit: { action, id in
        _ = state.start(action, request: self.request, at: root, valid: { true }, writable: { true }, draftID: id)
      })
  }

  func testMountedGeneralCommentDoesNotAutofocusAndSubmitsTrimmedBody() async throws {
    let (directory, state) = try await fixture()
    let (window, root, text) = try await host(TaskPullRequestActivityView(state: state, enabled: true,
      writable: true, mentionRequest: nil, open: { _ in }, retry: {}, confirm: {}, submit: { action, id in
        _ = state.start(action, request: self.request, at: directory, valid: { true }, writable: { true }, draftID: id)
      }))
    XCTAssertFalse(window.firstResponder === text); XCTAssertEqual(text.placeholder, "发表评论")
    XCTAssertTrue(window.makeFirstResponder(text)); text.insertText(" \n ", replacementRange: .init(location: 0, length: 0))
    text.keyDown(with: try key(36, window, .command)); XCTAssertFalse(state.busy)
    text.selectAll(nil); text.insertText("  Comment\n ", replacementRange: text.selectedRange()); await tick()
    text.keyDown(with: try key(36, window, .command)); await state.operation?.value
    for _ in 0..<3 { await tick(); root.layoutSubtreeIfNeeded() }
    XCTAssertEqual(state.commentBody, ""); XCTAssertEqual(text.string, "")
    XCTAssertEqual(try writes(directory).map { $0["body"] as? String }, ["Comment"])
    XCTAssertEqual(state.snapshot?.comments.last?.body, "Comment")
  }

  func testMountedEditKeyboardSubmitsRawDraftOnceAndPendingLocksEditor() async throws {
    let (directory, state) = try await fixture(["discussionMutationDelay": 0.1])
    let comment = try XCTUnwrap(state.snapshot?.comment("one")); state.beginEdit(comment)
    let (window, root, text) = try await host(content(state, comment, directory))
    text.selectAll(nil); text.insertText("  Raw\n ", replacementRange: text.selectedRange()); await tick()
    XCTAssertEqual(state.drafts[comment.id]?.text, "  Raw\n ")
    text.keyDown(with: try key(36, window, .command)); await tick(); root.layoutSubtreeIfNeeded()
    XCTAssertTrue(state.busy); XCTAssertFalse(state.canEdit(.draft(comment.id), writable: true))
    text.keyDown(with: try key(36, window, .control)); state.cancelDraft(comment.id)
    XCTAssertNotNil(state.drafts[comment.id]); await state.operation?.value
    XCTAssertNil(state.drafts[comment.id]); XCTAssertEqual(state.snapshot?.comment(comment.id)?.body, "  Raw\n ")
    XCTAssertEqual(try writes(directory).map { $0["body"] as? String }, ["  Raw\n "])
  }

  func testMountedReplyKeyboardTrimsBodyAndSuccessRemovesComposer() async throws {
    let (directory, state) = try await fixture()
    let comment = try XCTUnwrap(state.snapshot?.comment("one")); state.beginReply(comment, thread: nil, quote: false)
    let (window, root, text) = try await host(content(state, comment, directory))
    XCTAssertEqual(text.placeholder, "回复 reviewer"); XCTAssertTrue(window.firstResponder === text)
    text.insertText("  Reply\n ", replacementRange: .init(location: 0, length: 0)); await tick()
    text.keyDown(with: try key(36, window, .control)); await state.operation?.value
    await tick(); root.layoutSubtreeIfNeeded(); await tick()
    XCTAssertNil(state.drafts[comment.id]); XCTAssertNil(editor(in: root))
    XCTAssertEqual(try writes(directory).map { $0["body"] as? String }, ["Reply"])
    XCTAssertEqual(state.snapshot?.comments.last?.body, "Reply")
  }

  func testMountedFailureRetainsDraftClearsLocalErrorOnTypingAndCancelRemovesEditor() async throws {
    let (directory, state) = try await fixture(["discussionMutationGraphQLError": true])
    let comment = try XCTUnwrap(state.snapshot?.comment("one")); state.beginEdit(comment)
    let (window, root, text) = try await host(content(state, comment, directory), width: 280)
    text.selectAll(nil); text.insertText("Retry", replacementRange: text.selectedRange())
    text.keyDown(with: try key(36, window, .command)); await state.operation?.value
    for _ in 0..<3 { await tick(); root.layoutSubtreeIfNeeded() }
    XCTAssertEqual(state.drafts[comment.id]?.text, "Retry"); XCTAssertNotNil(state.message(for: .draft(comment.id)))
    XCTAssertTrue(text.isEditable); try render(root, "edit-failure-narrow")
    text.setSelectedRange(.init(location: 5, length: 0)); text.insertText(" again", replacementRange: text.selectedRange())
    XCTAssertEqual(state.drafts[comment.id]?.text, "Retry again"); XCTAssertNil(state.message(for: .draft(comment.id)))
    state.cancelDraft(comment.id); for _ in 0..<3 { await tick(); root.layoutSubtreeIfNeeded() }
    XCTAssertNil(editor(in: root)); XCTAssertEqual(try writes(directory).count, 1)
  }
}
