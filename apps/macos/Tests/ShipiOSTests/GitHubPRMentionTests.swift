import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

final class GitHubPRMentionTests: XCTestCase {
  private let request = GitHubPullRequest(number: 42, url: "https://github.com/sample/project/pull/42",
    title: "Feature", isDraft: false, headRefName: "feature/topic", baseRefName: "main", isCrossRepository: false)
  private func user(_ name: String) -> [String: Any] { ["login": name, "avatarUrl": "https://avatars.githubusercontent.com/u/1"] }
  private func fixture(_ extra: [String: Any] = [:]) async throws -> (GitHubPRMentionRequest, GitHubPRService) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pr-mentions-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    _ = try await GitReviewService.checked(["init", "-q", "-b", "feature/topic"], at: root)
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/github_cli.py")
    let executable = root.appendingPathComponent(".git/gh-fixture")
    try FileManager.default.copyItem(at: source, to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let item = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
    var state: [String: Any] = ["head": String(repeating: "a", count: 40), "pullRequests": [item], "viewer": "reviewer",
      "mentionParticipants": [user("alice"), user("bob")], "mentionableUsers": [user("alex"), user("bert")]]
    extra.forEach { state[$0.key] = $0.value }
    try JSONSerialization.data(withJSONObject: state).write(to: root.appendingPathComponent(".git/github-fixture.json"), options: .atomic)
    return (.init(pullRequest: request, root: root, viewer: "reviewer"), .init(executable: executable))
  }
  private func logs(_ root: URL) throws -> [[String: Any]] {
    let file = root.appendingPathComponent(".git/github-requests.jsonl")
    guard FileManager.default.fileExists(atPath: file.path) else { return [] }
    return try String(contentsOf: file, encoding: .utf8).split(separator: "\n").compactMap {
      let value = (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
      return ((value?["input"] as? [String: Any])?["query"] as? String)?.contains("ShipiOSPRMentionUsers") == true ? value : nil
    }
  }
  private func queries(_ root: URL) throws -> [String] {
    try logs(root).compactMap { (($0["input"] as? [String: Any])?["variables"] as? [String: Any])?["search"] as? String }
  }
  private func key(_ code: UInt16, _ text: String, _ modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
      timestamp: 0, windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
      isARepeat: false, keyCode: code))
  }

  func testUTF16TokenDetectionReplacesWholeLoginWithoutChangingSuffix() throws {
    let text = "你好😀 @alBob!"
    let caret = ("你好😀 @al" as NSString).length
    let token = try XCTUnwrap(GitHubPRMentionToken.detect(text: text, selection: .init(location: caret, length: 0)))
    XCTAssertEqual(token.query, "al")
    XCTAssertEqual((text as NSString).substring(with: token.range), "@alBob")
    let replacement = try XCTUnwrap(token.replacement(login: "alice", in: text))
    XCTAssertEqual((text as NSString).replacingCharacters(in: replacement.range, with: replacement.text), "你好😀 @alice!")
    XCTAssertEqual(replacement.selection.location, caret)
    let end = try XCTUnwrap(GitHubPRMentionToken.detect(text: "@al", selection: .init(location: 3, length: 0)))
    XCTAssertEqual(end.replacement(login: "alice", in: "@al")?.text, "@alice ")
  }

  func testTokenBoundariesEmailsSelectionsAndInvalidLoginCannotReplaceText() {
    for text in ["name@example", "file@abc", "a_@abc", "hello world"] {
      XCTAssertNil(GitHubPRMentionToken.detect(text: text, selection: .init(location: text.utf16.count, length: 0)))
    }
    for text in ["@", "中文@abc", "(@abc", "`@abc", " @a-b_2"] {
      XCTAssertNotNil(GitHubPRMentionToken.detect(text: text, selection: .init(location: text.utf16.count, length: 0)))
    }
    XCTAssertNil(GitHubPRMentionToken.detect(text: "@ab", selection: .init(location: 1, length: 1)))
    XCTAssertNil(GitHubPRMentionToken.detect(text: "@ab", selection: .init(location: NSNotFound, length: 0)))
    let token = GitHubPRMentionToken.detect(text: "@ab", selection: .init(location: 3, length: 0))
    XCTAssertNil(token?.replacement(login: "bad/path", in: "@ab"))
    XCTAssertNil(token?.replacement(login: "", in: "@ab"))
  }

  func testScopedQueryMergesParticipantsFirstDeduplicatesAndCapsTen() async throws {
    let participants = [user("Alice"), user("ALICE"), user("allie"), user("bob")]
    let candidates = [user("alice")] + (0..<12).map { user("alex\($0)") }
    let (context, service) = try await fixture(["mentionParticipants": participants, "mentionableUsers": candidates])
    let base = try await service.mentionUsers(context, query: "")
    XCTAssertEqual(base.map(\.login), ["Alice", "allie", "bob"])
    let result = try await service.mentionUsers(context, query: "al")
    XCTAssertEqual(Array(result.prefix(2)).map(\.login), ["Alice", "allie"])
    XCTAssertEqual(result.count, 10); XCTAssertEqual(Set(result.map(\.id)).count, 10)
    for entry in try logs(context.root) {
      XCTAssertEqual(entry["inputMode"] as? String, "0o600"); XCTAssertEqual(entry["folderMode"] as? String, "0o700")
      let args = try XCTUnwrap(entry["args"] as? [String])
      let file = args[try XCTUnwrap(args.firstIndex(of: "--input")) + 1]
      XCTAssertFalse(FileManager.default.fileExists(atPath: file))
    }
  }

  func testAccountRepositoryPRAndGraphQLFailuresDoNotReturnCandidates() async throws {
    for fields: [String: Any] in [["mentionViewer": "someone-else"], ["metadataRepository": "other/repo"],
      ["mentionMismatch": true], ["mentionGraphQLError": true], ["mentionFailure": true]] {
      let (context, service) = try await fixture(fields)
      do { _ = try await service.mentionUsers(context, query: "al"); XCTFail("Expected scoped search failure") } catch {}
    }
  }

  @MainActor func testInitialParticipantsSingleCharacterFilterAndEmptyState() async throws {
    let (context, service) = try await fixture(), state = GitHubPRMentionState(service: service, debounce: .milliseconds(5))
    state.setContext(context); state.select(text: "@", range: .init(location: 1, length: 0))
    await state.baseTask?.value
    XCTAssertEqual(state.users.map(\.login), ["alice", "bob"]); XCTAssertEqual(state.highlighted, 0)
    state.select(text: "@a", range: .init(location: 2, length: 0))
    XCTAssertEqual(state.users.map(\.login), ["alice"]); XCTAssertTrue(state.visible)
    state.select(text: "@z", range: .init(location: 2, length: 0))
    XCTAssertFalse(state.visible); XCTAssertEqual(try queries(context.root), [""])
    state.select(text: "@zz", range: .init(location: 3, length: 0)); await state.searchTask?.value
    XCTAssertTrue(state.visible); XCTAssertTrue(state.users.isEmpty); XCTAssertFalse(state.loading); XCTAssertNil(state.error)
  }

  @MainActor func testDebounceCancelsOldQueryAndDismissalPersistsUntilCaretLeavesToken() async throws {
    let (context, service) = try await fixture(), state = GitHubPRMentionState(service: service, debounce: .milliseconds(100))
    state.setContext(context); state.select(text: "@al", range: .init(location: 3, length: 0))
    let firstSearch = state.searchTask
    state.select(text: "@be", range: .init(location: 3, length: 0))
    await state.baseTask?.value; await firstSearch?.value; await state.searchTask?.value
    XCTAssertEqual(state.users.map(\.login), ["bert"])
    XCTAssertFalse(try queries(context.root).contains("al"))
    state.dismiss(); state.select(text: "@bert", range: .init(location: 5, length: 0)); XCTAssertFalse(state.visible)
    state.select(text: "@bert ", range: .init(location: 6, length: 0))
    state.select(text: "@", range: .init(location: 1, length: 0)); XCTAssertTrue(state.visible)
    state.move(-1); XCTAssertEqual(state.highlighted, 1)
    XCTAssertTrue(state.choose()); XCTAssertEqual(state.replacement?.text, "@bob ")
  }

  @MainActor func testFailureAndChangingContextCancelLateCandidateResults() async throws {
    let (context, service) = try await fixture(["mentionFailure": true]), state = GitHubPRMentionState(service: service, debounce: .milliseconds(5))
    state.setContext(context); state.select(text: "@ab", range: .init(location: 3, length: 0))
    await state.baseTask?.value; await state.searchTask?.value
    XCTAssertNotNil(state.error); XCTAssertFalse(state.loading); XCTAssertTrue(state.visible)
    let (other, delayedService) = try await fixture(["mentionDelay": 0.15])
    let delayed = GitHubPRMentionState(service: delayedService, debounce: .milliseconds(5))
    delayed.setContext(other); delayed.select(text: "@al", range: .init(location: 3, length: 0))
    let base = delayed.baseTask, search = delayed.searchTask
    delayed.setContext(nil); await base?.value; await search?.value
    XCTAssertNil(delayed.token); XCTAssertTrue(delayed.users.isEmpty); XCTAssertNil(delayed.error); XCTAssertNil(delayed.replacement)
  }

  @MainActor func testNativeMentionInsertionUndoRedoAndStaleSelectionProtection() async throws {
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 320, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false; defer { window.close() }
    var text = "中文😀 @al!"
    let view = PullRequestTextEditor(text: Binding(get: { text }, set: { text = $0 }), field: .body, focus: nil, submit: {}, cancel: {})
    let coordinator = view.makeCoordinator()
    let editor = PullRequestTextEditor.TextView(frame: .init(x: 0, y: 0, width: 300, height: 100))
    editor.isRichText = false; editor.allowsUndo = true; editor.field = .body; editor.delegate = coordinator
    window.contentView?.addSubview(editor); window.makeFirstResponder(editor)
    editor.string = text; let caret = ("中文😀 @al" as NSString).length
    editor.setSelectedRange(.init(location: caret, length: 0))
    let token = try XCTUnwrap(GitHubPRMentionToken.detect(text: text, selection: editor.selectedRange()))
    let replacement = try XCTUnwrap(token.replacement(login: "alice", in: text))
    XCTAssertTrue(editor.apply(replacement)); XCTAssertEqual(text, "中文😀 @alice!")
    let undo = try XCTUnwrap(editor.undoManager); undo.undo(); XCTAssertEqual(text, "中文😀 @al!")
    undo.redo(); XCTAssertEqual(text, "中文😀 @alice!")
    XCTAssertFalse(editor.apply(replacement), "An already applied or stale replacement must not apply twice")
    editor.string = replacement.expectedText; editor.setSelectedRange(.init(location: 0, length: 0))
    XCTAssertFalse(editor.apply(replacement), "Moving the caret invalidates the captured suggestion")
    editor.setSelectedRange(replacement.selection); editor.isEditable = false; XCTAssertFalse(editor.apply(replacement))
  }

  @MainActor func testNativeKeysSelectCandidateAndCmdEnterSubmitsWithoutIMEInterception() async throws {
    let (context, service) = try await fixture(), state = GitHubPRMentionState(service: service, debounce: .milliseconds(5))
    state.setContext(context); state.select(text: "@", range: .init(location: 1, length: 0)); await state.baseTask?.value
    let editor = PullRequestTextEditor.TextView(frame: .init(x: 0, y: 0, width: 300, height: 100))
    editor.field = .body; editor.isRichText = false; editor.string = "@"; editor.setSelectedRange(.init(location: 1, length: 0))
    var submissions = 0; editor.submit = { submissions += 1 }
    editor.handleKey = { GitHubPRMentionKeyboard.handle($0, state: state) }
    editor.keyDown(with: try key(125, "\u{f701}")); XCTAssertEqual(state.highlighted, 1)
    editor.keyDown(with: try key(48, "\t")); XCTAssertEqual(state.replacement?.text, "@bob ")
    XCTAssertEqual(editor.string, "@", "Tab selects a suggestion rather than inserting a tab")
    XCTAssertTrue(editor.apply(try XCTUnwrap(state.replacement))); XCTAssertEqual(editor.string, "@bob ")
    state.select(text: "@ ", range: .init(location: 2, length: 0)); state.select(text: "@", range: .init(location: 1, length: 0))
    editor.keyDown(with: try key(36, "\r", .command)); XCTAssertEqual(submissions, 1); XCTAssertFalse(state.visible)
    state.select(text: "x @", range: .init(location: 3, length: 0))
    editor.setMarkedText("拼音", selectedRange: .init(location: 2, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
    let highlighted = state.highlighted
    editor.keyDown(with: try key(36, "\r", .command)); XCTAssertEqual(submissions, 1)
    XCTAssertEqual(state.highlighted, highlighted, "The IME handles composing keys before mention navigation")
    editor.unmarkText(); state.dismiss()
  }

  @MainActor func testOneMinuteCacheSharesEditorsAndRefreshesExpiredParticipants() async throws {
    var date = Date(timeIntervalSince1970: 1000)
    let cache = GitHubPRMentionCache(now: { date }), (context, service) = try await fixture()
    let first = GitHubPRMentionState(service: service, cache: cache)
    first.setContext(context); first.select(text: "@", range: .init(location: 1, length: 0)); await first.baseTask?.value
    let second = GitHubPRMentionState(service: service, cache: cache)
    second.setContext(context); second.select(text: "@", range: .init(location: 1, length: 0)); await second.baseTask?.value
    XCTAssertEqual(second.users.map(\.login), ["alice", "bob"]); XCTAssertEqual(try queries(context.root), [""])
    date = date.addingTimeInterval(61)
    first.blurred(); first.select(text: "@", range: .init(location: 1, length: 0)); await first.baseTask?.value
    XCTAssertEqual(first.users.map(\.login), ["alice", "bob"]); XCTAssertEqual(try queries(context.root), ["", ""])
    let differentAccount = GitHubPRMentionRequest(pullRequest: context.pullRequest, root: context.root, viewer: "other")
    XCTAssertNil(cache.fresh(differentAccount, query: "", service: service))
    XCTAssertNil(cache.fresh(context, query: "al", service: service))
  }

  @MainActor func testSharedInFlightQuerySurvivesOneEditorCancellation() async throws {
    let (context, service) = try await fixture(["mentionDelay": 0.15]), cache = GitHubPRMentionCache()
    let first = Task { try await cache.users(context, query: "al", service: service) }
    let second = Task { try await cache.users(context, query: "al", service: service) }
    try await Task.sleep(for: .milliseconds(50)); first.cancel()
    let users = try await second.value
    do { _ = try await first.value; XCTFail("Cancelled editor must not receive candidates") } catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(users.map(\.login), ["alice", "alex"])
    XCTAssertEqual(try queries(context.root), ["al"])
    XCTAssertEqual(cache.fresh(context, query: "al", service: service), users)
  }

  @MainActor func testFailedQueriesAreNotCachedOrRetriedAutomatically() async throws {
    let (context, service) = try await fixture(["mentionFailure": true]), cache = GitHubPRMentionCache()
    for _ in 0..<2 {
      do { _ = try await cache.users(context, query: "al", service: service); XCTFail("Expected failure") } catch {}
      XCTAssertNil(cache.fresh(context, query: "al", service: service))
    }
    XCTAssertEqual(try queries(context.root), ["al", "al"])
  }

  @MainActor func testFloatingPickerPlacementFitsWindowAndDoesNotAcceptFocus() throws {
    let viewport = NSRect(x: 0, y: 0, width: 600, height: 500)
    let above = try XCTUnwrap(PullRequestMentionPopover.placement(anchor: .init(x: 100, y: 50, width: 300, height: 100), viewport: viewport, height: 180))
    XCTAssertEqual(above, .init(x: 100, y: 158, width: 300, height: 180))
    let below = try XCTUnwrap(PullRequestMentionPopover.placement(anchor: .init(x: 100, y: 350, width: 300, height: 100), viewport: viewport, height: 180))
    XCTAssertEqual(below, .init(x: 100, y: 162, width: 300, height: 180))
    let narrow = try XCTUnwrap(PullRequestMentionPopover.placement(anchor: .init(x: -10, y: 80, width: 800, height: 60), viewport: viewport, height: 450))
    XCTAssertTrue(viewport.insetBy(dx: 6, dy: 6).contains(narrow)); XCTAssertEqual(narrow.width, 588)
    XCTAssertNil(PullRequestMentionPopover.placement(anchor: .init(x: 100, y: 550, width: 300, height: 60), viewport: viewport, height: 180))
    let host = PullRequestMentionPopover.HostingView(rootView: AnyView(Text("Candidate")))
    XCTAssertFalse(host.acceptsFirstResponder); XCTAssertFalse(host.canBecomeKeyView)
  }


  @MainActor func testNativePopoverLivesOutsideScrollClippingAndDetachesWithoutChangingFocus() async throws {
    let (context, service) = try await fixture(["mentionParticipants": [["login": "alice"], ["login": "bob"]]]), state = GitHubPRMentionState(service: service)
    state.setContext(context); state.select(text: "@", range: .init(location: 1, length: 0)); await state.baseTask?.value
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let content = try XCTUnwrap(window.contentView)
    let scroll = NSScrollView(frame: .init(x: 20, y: 20, width: 300, height: 50))
    let document = NSView(frame: .init(x: 0, y: 0, width: 300, height: 800))
    let bridge = PullRequestMentionPopover(state: state, enabled: true), coordinator = bridge.makeCoordinator()
    defer { coordinator.detach() }
    let anchor = PullRequestMentionPopover.AnchorView(frame: .init(x: 0, y: 0, width: 300, height: 38))
    anchor.owner = coordinator; document.addSubview(anchor); scroll.documentView = document; content.addSubview(scroll)
    let editor = PullRequestTextEditor.TextView(frame: .init(x: 350, y: 20, width: 200, height: 80))
    content.addSubview(editor); XCTAssertTrue(window.makeFirstResponder(editor))
    coordinator.attach(anchor)
    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    let host = try XCTUnwrap(content.subviews.compactMap { $0 as? PullRequestMentionPopover.HostingView }.first)
    XCTAssertTrue(host.superview === content); XCTAssertTrue(window.firstResponder === editor)
    let visibleScroll = scroll.convert(scroll.bounds, to: content)
    XCTAssertGreaterThan(host.frame.maxY, visibleScroll.maxY, "Candidate content must escape the scroll clip")
    anchor.removeFromSuperview()
    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    XCTAssertFalse(content.subviews.contains { $0 is PullRequestMentionPopover.HostingView })
    XCTAssertTrue(window.firstResponder === editor)
  }


  @MainActor func testRenderedCommentEditorGrowsByLineHeightAndCapsLongInput() async throws {
    func findEditor(_ view: NSView) -> PullRequestTextEditor.TextView? {
      if let editor = view as? PullRequestTextEditor.TextView { return editor }
      return view.subviews.lazy.compactMap { findEditor($0) }.first
    }
    func measure(_ text: String) async throws -> CGFloat {
      let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 360, height: 420), styleMask: [.titled], backing: .buffered, defer: true)
      window.isReleasedWhenClosed = false; defer { window.close() }
      let view = TaskPullRequestCommentComposer(text: .constant(text), label: "发表评论", focus: nil,
        enabled: true, busy: false, cancel: nil, submit: {})
      let host = NSHostingView(rootView: view)
      window.contentView = host
      for _ in 0..<3 {
        host.layoutSubtreeIfNeeded()
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
      }
      let editor = try XCTUnwrap(findEditor(host))
      XCTAssertEqual(editor.string, text); XCTAssertEqual(editor.font?.pointSize, 16)
      return try XCTUnwrap(editor.enclosingScrollView).frame.height
    }
    let one = try await measure("First line"), two = try await measure("First line\nSecond line")
    XCTAssertGreaterThanOrEqual(one, 38); XCTAssertEqual(two - one, 28, accuracy: 1)
    let long = try await measure(Array(repeating: "A line", count: 100).joined(separator: "\n"))
    XCTAssertEqual(long, 192, accuracy: 1)
  }

}
