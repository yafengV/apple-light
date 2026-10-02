import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class GitHubPRCommentCollapseTests: XCTestCase {
  private func comment(_ id: String, type: String = "User", body: String = "Body") -> GitHubPRComment {
    .init(id: id, kind: .code, body: body, author: "author", authorType: type, createdAt: "2026-09-29T10:00:00Z",
      url: nil, canUpdate: true, canDelete: true)
  }
  private func card(_ id: String, type: String = "User", resolved: Bool? = nil, replies: [GitHubPRComment] = []) -> GitHubPRCommentCard {
    let root = comment(id, type: type)
    let thread = resolved.map { GitHubPRReviewThread(id: id + "-thread", path: "Sources/Main.swift", line: 12,
      originalLine: 10, diffHunk: "", isResolved: $0, isOutdated: false, canReply: true, canResolve: true,
      canUnresolve: true, comments: [root] + replies, diffSide: "RIGHT") }
    return .init(comment: root, thread: thread)
  }
  private func edit(_ comment: GitHubPRComment, text: String = "") -> GitHubPRCommentDraft { .init(target: .edit(comment), text: text) }
  private func reply(_ id: String, text: String) -> GitHubPRCommentDraft {
    .init(target: .reply(commentID: id, threadID: nil), text: text)
  }

  func testUsersExpandBotsAndResolvedThreadsCollapseByDefault() {
    let state = GitHubPRCommentCollapseState(), cards = [card("user"), card("bot", type: "Bot"), card("resolved", resolved: true)]
    state.sync(cards, drafts: [:])
    XCTAssertEqual(cards.map { state.isCollapsed($0, drafts: [:]) }, [false, true, true])
  }
  func testSingleToggleKeepsOtherCardsAndOtherWindowsIndependent() {
    let a = card("a"), b = card("b"), state = GitHubPRCommentCollapseState(), other = GitHubPRCommentCollapseState()
    state.toggle(a, all: false, cards: [a, b], drafts: [:])
    XCTAssertTrue(state.isCollapsed(a, drafts: [:])); XCTAssertFalse(state.isCollapsed(b, drafts: [:]))
    XCTAssertFalse(other.isCollapsed(a, drafts: [:]))
    state.toggle(a, all: false, cards: [a, b], drafts: [:]); XCTAssertFalse(state.isCollapsed(a, drafts: [:]))
  }
  func testOptionAppliesInitiatingCardsTargetToMixedStates() {
    let a = card("a"), bot = card("bot", type: "Bot"), state = GitHubPRCommentCollapseState()
    state.toggle(a, all: true, cards: [a, bot], drafts: [:])
    XCTAssertTrue(state.isCollapsed(a, drafts: [:])); XCTAssertTrue(state.isCollapsed(bot, drafts: [:]))
    state.toggle(bot, all: true, cards: [a, bot], drafts: [:])
    XCTAssertFalse(state.isCollapsed(a, drafts: [:])); XCTAssertFalse(state.isCollapsed(bot, drafts: [:]))
  }
  func testBulkCollapseSkipsEmptyEditsAndNonemptyReplies() {
    let a = card("a"), b = card("b"), c = card("c"), state = GitHubPRCommentCollapseState()
    let drafts = ["b": edit(b.comment), "c": reply("c", text: " ")]
    state.toggle(a, all: true, cards: [a, b, c], drafts: drafts)
    XCTAssertTrue(state.isCollapsed(a, drafts: drafts))
    XCTAssertFalse(state.isCollapsed(b, drafts: drafts)); XCTAssertFalse(state.isCollapsed(c, drafts: drafts))
    XCTAssertEqual(drafts["c"]?.text, " ")
  }
  func testDirtyInitiatingCardCannotCollapseEntireGroup() {
    let a = card("a"), b = card("b"), state = GitHubPRCommentCollapseState(), drafts = ["a": reply("a", text: "Draft")]
    state.toggle(a, all: true, cards: [a, b], drafts: drafts)
    XCTAssertFalse(state.isCollapsed(a, drafts: drafts)); XCTAssertFalse(state.isCollapsed(b, drafts: drafts))
  }
  func testEmptyReplyCanCollapseAndDraftRemainsIntact() {
    let a = card("a"), state = GitHubPRCommentCollapseState(), drafts = ["a": reply("a", text: "")]
    state.toggle(a, all: false, cards: [a], drafts: drafts); state.sync([a], drafts: drafts)
    XCTAssertTrue(state.isCollapsed(a, drafts: drafts)); XCTAssertEqual(drafts.count, 1)
  }
  func testReplyEditingProtectsWholeThreadAndForeignDraftDoesNot() {
    let reply = comment("reply"), a = card("a", resolved: true, replies: [reply]), state = GitHubPRCommentCollapseState()
    XCTAssertFalse(state.isCollapsed(a, drafts: ["reply": edit(reply)]))
    XCTAssertTrue(state.isCollapsed(a, drafts: ["foreign": edit(comment("foreign"))]))
  }
  func testResolveUnresolveAndAuthorTypeChangesResetManualCollapse() {
    let state = GitHubPRCommentCollapseState(), open = card("a", resolved: false), resolved = card("a", resolved: true)
    state.sync([open], drafts: [:]); state.sync([resolved], drafts: [:]); XCTAssertTrue(state.isCollapsed(resolved, drafts: [:]))
    state.expand(resolved); XCTAssertFalse(state.isCollapsed(resolved, drafts: [:]))
    state.sync([open], drafts: [:]); XCTAssertFalse(state.isCollapsed(open, drafts: [:]))
    let bot = card("a", type: "Bot", resolved: false)
    state.sync([bot], drafts: [:]); XCTAssertTrue(state.isCollapsed(bot, drafts: [:]))
  }
  func testResolvedStateChangeCannotHideEditorAndCancelKeepsOpenCard() {
    let state = GitHubPRCommentCollapseState(), open = card("a", resolved: false), resolved = card("a", resolved: true)
    let drafts = ["a": edit(open.comment)]
    state.sync([open], drafts: drafts); state.sync([resolved], drafts: drafts)
    XCTAssertFalse(state.isCollapsed(resolved, drafts: drafts))
    state.sync([resolved], drafts: [:]); XCTAssertFalse(state.isCollapsed(resolved, drafts: [:]))
  }
  func testBackgroundRefreshPreservesManualStateAndRemovedCardsDoNotLeak() {
    let state = GitHubPRCommentCollapseState(), a = card("a"), b = card("b")
    state.toggle(a, all: false, cards: [a], drafts: [:]); state.sync([a, b], drafts: [:])
    XCTAssertTrue(state.isCollapsed(a, drafts: [:])); XCTAssertFalse(state.isCollapsed(b, drafts: [:]))
    state.sync([b], drafts: [:]); state.sync([a, b], drafts: [:]); XCTAssertFalse(state.isCollapsed(a, drafts: [:]))
  }
  func testThreadReplyPresentationFiltersBlankBodiesButRetainsOriginalMembership() {
    let a = card("a", resolved: false, replies: [comment("blank", body: " \n"), comment("visible")])
    XCTAssertEqual(a.replies.map(\.id), ["visible"]); XCTAssertEqual(a.thread?.comments.count, 3)
    XCTAssertTrue(a.allIDs.contains("blank"))
  }
  func testLongCommentBodyUsesThreeLinePreviewWithoutExpandingTheCard() async throws {
    _ = NSApplication.shared
    let state = GitHubPRDiscussionState()
    let long = comment("long", body: Array(repeating: "一段较长的评论正文。", count: 15)
      .joined(separator: "\n\n"))
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 500),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let host = NSHostingView(rootView: TaskPullRequestCommentContentView(comment: long,
      state: state, enabled: false, writable: false, mentionRequest: nil,
      open: { _ in }, submit: { _, _ in }).frame(width: 400))
    window.contentView = host
    try await Task.sleep(for: .milliseconds(400))
    host.layoutSubtreeIfNeeded()
    XCTAssertLessThan(host.fittingSize.height, 120)
    XCTAssertGreaterThan(host.fittingSize.height, 60)
    XCTAssertFalse(window.isVisible)
  }
  func testSnapshotBuildsOnlyVisibleCardsWithThreadIdentityAndOrder() {
    let a = card("a", resolved: false, replies: [comment("reply")])
    var snapshot = GitHubPRDiscussionSnapshot(requestURL: "url", nodeID: "pr", viewer: "viewer", author: "author", state: "OPEN",
      head: "head", comments: [], threads: [a.thread!], events: [], omittedTypes: [])
    snapshot.comments = [.init(id: "issue", kind: .issue, body: "Body", author: "author", authorType: "User",
      createdAt: "2026-09-29T09:00:00Z", url: nil, canUpdate: true, canDelete: true)]
    XCTAssertEqual(snapshot.commentCards.map(\.id), ["issue", "a"])
    XCTAssertEqual(snapshot.commentCards.last?.replies.map(\.id), ["reply"])
  }
  func testOffscreenBotCardExpandsAndCollapsesThreadRepliesWithoutNewWindows() async throws {
    _ = NSApplication.shared
    let card = card("root", type: "Bot", resolved: false, replies: [comment("reply", body: String(repeating: "Reply\n\n", count: 10))])
    let collapse = GitHubPRCommentCollapseState(), state = GitHubPRDiscussionState()
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 640, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let host = NSHostingView(rootView: TaskPullRequestCommentView(card: card, collapse: collapse, state: state,
      enabled: false, writable: false, mentionRequest: nil, open: { _ in }, submit: { _, _ in }).frame(width: 640))
    window.contentView = host
    try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
    let collapsed = host.fittingSize.height
    collapse.expand(card)
    try await Task.sleep(for: .milliseconds(300)); host.layoutSubtreeIfNeeded()
    let expanded = host.fittingSize.height
    XCTAssertGreaterThan(expanded, collapsed + 100)
    collapse.toggle(card, all: false, cards: [card], drafts: [:])
    try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
    XCTAssertEqual(host.fittingSize.height, collapsed, accuracy: 2)
    XCTAssertFalse(window.isVisible, "Tests must not show or foreground a native window")
  }
}
