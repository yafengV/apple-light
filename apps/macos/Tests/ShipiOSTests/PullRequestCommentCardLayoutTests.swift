import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class PullRequestCommentCardLayoutTests: XCTestCase {
  private struct Anchor: NSViewRepresentable {
    let capture: (NSView) -> Void
    func makeNSView(context: Context) -> NSView { let view = NSView(); capture(view); return view }
    func updateNSView(_ view: NSView, context: Context) {}
  }
  private func comment(_ id: String = "root", body: String = "Body", type: String = "User") -> GitHubPRComment {
    .init(id: id, kind: .code, body: body, author: "author", authorType: type, createdAt: "", url: nil, canUpdate: true, canDelete: true)
  }
  private func card(type: String = "User", body: String = "Body", replies: [GitHubPRComment] = [], resolved: Bool = false, inline: Bool = false) -> GitHubPRCommentCard {
    let c = comment(body: body, type: type)
    let thread = replies.isEmpty && !resolved ? nil : GitHubPRReviewThread(id: "thread", path: "Main.swift", line: 1,
      originalLine: 1, diffHunk: "", isResolved: resolved, isOutdated: false, canReply: true, canResolve: true, canUnresolve: true, comments: [c] + replies)
    return .init(comment: c, thread: thread, isInline: inline)
  }
  private func reference() throws -> [String: Any] {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/pr_comment_card_reference.json")
    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
  }
  private func settle(_ root: NSView) async throws {
    for _ in 0..<4 { root.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(50)) }
  }
  private func host<V: View>(_ view: V, width: CGFloat = 500, height: CGFloat = 1000) async throws -> (NSWindow, NSHostingView<AnyView>, NSView) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
    var captured: NSView?, preferences = AppearancePreferences(); preferences.theme = "light"
    let root = NSHostingView(rootView: AnyView(VStack(spacing: 0) {
      view.fixedSize(horizontal: false, vertical: true).frame(width: width).background { Anchor { captured = $0 } }
      Spacer(minLength: 0)
    }.frame(width: width, height: height, alignment: .top).environment(\.appAppearance, preferences)))
    window.contentView = root; try await settle(root)
    addTeardownBlock { @MainActor in window.contentView = nil; window.close() }
    return (window, root, try XCTUnwrap(captured))
  }
  private func render(_ view: NSView, _ name: String) throws {
    guard let directory = ProcessInfo.processInfo.environment["SHIPIOS_PR_COMMENT_CARD_RENDER_DIR"] else { return }
    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
  }
  private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
    (view as? T) ?? view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
  }
  private func content(_ c: GitHubPRComment, reply: Bool = false, protected: Bool = false) -> some View {
    TaskPullRequestCommentContentView(comment: c, state: .init(), enabled: false, writable: false,
      mentionRequest: nil, open: { _ in }, submit: { _, _ in }, isReply: reply, preventsTruncation: protected)
  }
  private func cardView(_ card: GitHubPRCommentCard, collapse: GitHubPRCommentCollapseState, state: GitHubPRDiscussionState? = nil) -> some View {
    TaskPullRequestCommentView(card: card, collapse: collapse, state: state ?? .init(), enabled: false, writable: false,
      mentionRequest: nil, open: { _ in }, submit: { _, _ in }, showsCodeContext: !card.isInline)
  }

  func testActualShellBodyReplyAndAdapterFactsMatchImplementedModes() throws {
    let facts = try reference(), shells = try XCTUnwrap(facts["shellCases"] as? [[String: Any]])
    XCTAssertEqual(facts["version"] as? String, "26.930.21537"); XCTAssertEqual(shells.count, 6)
    XCTAssertEqual(facts["shellSHA256"] as? String, "7a4c054876e1535be217b63d0c65bb63e051caf9b5ca87597693fa13ef5d1284")
    for sample in shells {
      let header = try XCTUnwrap(sample["headerClass"] as? String)
      XCTAssertTrue(header.contains("px-3 pt-2")); XCTAssertTrue(header.contains(sample["name"] as? String == "collapsed" ? "pb-2" : "pb-0.5"))
      let root = try XCTUnwrap(sample["rootClass"] as? String)
      XCTAssertEqual(root.contains("border border-default"), sample["name"] as? String != "inline")
    }
    let bodies = try XCTUnwrap(facts["bodyCases"] as? [[String: Any]])
    XCTAssertEqual(bodies[1]["contentClass"] as? String, "line-clamp-6"); XCTAssertTrue(bodies[2]["moreClass"] is NSNull)
    let replies = try XCTUnwrap(facts["replyFacts"] as? [String: Any])
    XCTAssertEqual(replies["bodyClass"] as? String, "ps-11.5 pe-3 pb-1.5 text-size-chat break-words text-default")
    let css = try XCTUnwrap(facts["cssDeclarations"] as? [[String: String]])
    func declaration(_ key: String, _ selector: String) -> String? {
      css.first { $0["key"] == key && $0["selector"] == selector }?["value"]
    }
    XCTAssertEqual(declaration("--text-base", "@layer theme{:root,:host"), "14px")
    XCTAssertEqual(declaration("--text-sm", "[data-codex-window-type=electron]"), "13px")
    XCTAssertEqual(declaration("--text-xs", "[data-codex-window-type=electron]"), "12px")
    XCTAssertEqual(declaration("--color-surface-elevated-secondary", ":where(:root,[data-theme])"),
      "var(--color-background-control-opaque,var(--app-color-background-surface))")
    XCTAssertEqual(declaration("--color-border-overlay", ":where(:root,[data-theme])"), "var(--color-border)")
    XCTAssertTrue(css.contains { $0["key"] == "--color-background-primary-soft-alpha"
      && $0["selector"]?.contains("[data-codex-window-type=electron]) body") == true
      && $0["value"] == "var(--app-color-background-elevated-secondary)" })
    let cases = try XCTUnwrap(facts["wrapperCases"] as? [[String: Any]])
    for sample in cases {
      let name = try XCTUnwrap(sample["name"] as? String)
      let c = card(type: name.contains("bot") ? "Bot" : "User", resolved: name == "resolved-inline", inline: sample["surfaceVariant"] as? String == "inline")
      XCTAssertEqual(c.defaultCollapsed, sample["defaultCollapsed"] as? Bool)
      let state = GitHubPRCommentCollapseState()
      var drafts: [String: GitHubPRCommentDraft] = [:]
      if name == "root-edit" { drafts[c.id] = .init(target: .edit(c.comment), text: "") }
      if name == "dirty-reply" { drafts[c.id] = .init(target: .reply(commentID: c.id, threadID: nil), text: "Reply") }
      XCTAssertEqual(state.preventsCollapse(c, drafts: drafts), sample["preventCollapse"] as? Bool)
    }
  }

  func testRichRootUsesSixLinesAndLongRepliesAndProtectedBodiesRemainComplete() async throws {
    let c = comment(body: Array(repeating: "A paragraph that is long enough to be visible.", count: 25).joined(separator: "\n\n"))
    let (_, root, preview) = try await host(content(c))
    XCTAssertGreaterThan(preview.bounds.height, 120); XCTAssertLessThan(preview.bounds.height, 160)
    try render(root, "root-six-lines")
    let (_, _, reply) = try await host(content(c, reply: true)), (_, _, protected) = try await host(content(c, protected: true))
    XCTAssertGreaterThan(reply.bounds.height, preview.bounds.height + 400)
    XCTAssertEqual(reply.bounds.height, protected.bounds.height, accuracy: 1)
    let (_, _, short) = try await host(content(comment(body: "One short line")))
    XCTAssertLessThan(short.bounds.height, 30)
  }

  func testCollapsedHeaderHasReferenceFortyPointHeightAndExpandedBodyAddsOnlyItsOwnInsets() async throws {
    let c = card(), collapse = GitHubPRCommentCollapseState(); collapse.toggle(c, all: false, cards: [c], drafts: [:])
    let (_, root, surface) = try await host(cardView(c, collapse: collapse))
    XCTAssertEqual(surface.bounds.height, 40, accuracy: 1); try render(root, "collapsed")
    collapse.expand(c); try await settle(root)
    let (_, _, body) = try await host(content(c.comment))
    XCTAssertEqual(surface.bounds.height, 34 + body.bounds.height + 12, accuracy: 1)
    try render(root, "expanded")
  }

  func testHeaderActuallyWrapsAccessoriesAndKeepsBothRowsInsideNarrowViewport() async throws {
    var identity: NSView?, accessory: NSView?
    let layout = PullRequestCommentHeaderLayout(minimumIdentityWidth: 80) {
      Color.clear.frame(height: 24).background { Anchor { identity = $0 } }
      Color.clear.frame(width: 104, height: 24).background { Anchor { accessory = $0 } }
    }
    let (_, _, wide) = try await host(layout, width: 300)
    let first = try XCTUnwrap(identity), second = try XCTUnwrap(accessory)
    XCTAssertEqual(wide.bounds.height, 24); XCTAssertEqual(first.convert(first.bounds, to: wide).minX, 0, accuracy: 0.01)
    XCTAssertEqual(second.convert(second.bounds, to: wide).maxX, 300, accuracy: 0.01)
    let (_, _, narrow) = try await host(layout, width: 160)
    let narrowFirst = try XCTUnwrap(identity), narrowSecond = try XCTUnwrap(accessory)
    XCTAssertEqual(narrow.bounds.height, 56)
    XCTAssertEqual(narrow.bounds.maxY - narrowFirst.convert(narrowFirst.bounds, to: narrow).maxY, 0, accuracy: 0.01)
    XCTAssertEqual(narrow.bounds.maxY - narrowSecond.convert(narrowSecond.bounds, to: narrow).maxY, 32, accuracy: 0.01)
    XCTAssertEqual(narrowSecond.convert(narrowSecond.bounds, to: narrow).minX, 0, accuracy: 0.01)
  }

  func testHeaderWrapsNaturalIdentityBeforeShrinkingToItsMinimumWidth() async throws {
    let layout = PullRequestCommentHeaderLayout(minimumIdentityWidth: 52) {
      Color.clear.frame(minWidth: 0, idealWidth: 150, maxWidth: .infinity).frame(height: 24)
      Color.clear.frame(width: 104, height: 24)
    }
    let (_, _, wide) = try await host(layout, width: 300)
    XCTAssertEqual(wide.bounds.height, 24)
    let (_, _, narrower) = try await host(layout, width: 220)
    XCTAssertEqual(narrower.bounds.height, 56)
  }

  func testWhitespaceReplyDoesNotProtectButNextLineAndEveryEditProtectTheWholeCard() {
    let c = card(), collapse = GitHubPRCommentCollapseState()
    for text in ["", " \n", "\u{FEFF}", "\u{A0}\u{3000}"] {
      let drafts = [c.id: GitHubPRCommentDraft(target: .reply(commentID: c.id, threadID: nil), text: text)]
      XCTAssertFalse(collapse.preventsCollapse(c, drafts: drafts)); collapse.toggle(c, all: false, cards: [c], drafts: drafts)
      XCTAssertTrue(collapse.isCollapsed(c, drafts: drafts)); collapse.expand(c)
      XCTAssertEqual(drafts[c.id]?.text, text)
    }
    for text in ["\u{85}", "Reply", "\u{200B}"] {
      let drafts = [c.id: GitHubPRCommentDraft(target: .reply(commentID: c.id, threadID: nil), text: text)]
      XCTAssertTrue(collapse.preventsCollapse(c, drafts: drafts)); collapse.toggle(c, all: false, cards: [c], drafts: drafts)
      XCTAssertFalse(collapse.isCollapsed(c, drafts: drafts))
    }
    XCTAssertTrue(collapse.preventsCollapse(c, drafts: [c.id: .init(target: .edit(c.comment), text: "")]))
  }

  func testInlineBotDefaultsStayIndependentFromActivityAndBulkToggleUsesInlineCards() {
    let activity = card(type: "Bot", replies: [comment("reply")]), inline = card(type: "Bot", replies: [comment("reply")], inline: true)
    let state = GitHubPRCommentCollapseState(), activityState = GitHubPRCommentCollapseState()
    let snapshot = GitHubPRDiscussionSnapshot(requestURL: "url", nodeID: "PR", viewer: "me", author: "author", state: "OPEN", head: "head",
      comments: [], threads: [inline.thread!], events: [], omittedTypes: [])
    XCTAssertEqual(snapshot.inlineCommentCards.map(\.isInline), [true])
    state.sync(snapshot.inlineCommentCards, drafts: [:]); activityState.sync([activity], drafts: [:])
    XCTAssertFalse(state.isCollapsed(inline, drafts: [:])); XCTAssertTrue(activityState.isCollapsed(activity, drafts: [:]))
    state.toggle(inline, all: true, cards: snapshot.inlineCommentCards, drafts: [:]); state.sync(snapshot.inlineCommentCards, drafts: [:])
    XCTAssertTrue(state.isCollapsed(inline, drafts: [:])); state.toggle(inline, all: true, cards: snapshot.inlineCommentCards, drafts: [:])
    XCTAssertFalse(state.isCollapsed(inline, drafts: [:])); XCTAssertTrue(activityState.isCollapsed(activity, drafts: [:]))
  }

  func testRootEditAndThreadReplyEditUseTheirActualNestedGutters() async throws {
    for reply in [false, true] {
      let r = comment("reply", body: " Raw reply "), c = card(replies: reply ? [r] : [])
      let state = GitHubPRDiscussionState(); state.beginEdit(reply ? r : c.comment)
      let (_, root, surface) = try await host(cardView(c, collapse: .init(), state: state))
      let editor = try XCTUnwrap(find(PullRequestTextEditor.TextView.self, in: root)), scroll = try XCTUnwrap(editor.enclosingScrollView)
      let frame = surface.convert(scroll.bounds, from: scroll)
      XCTAssertEqual(frame.minX, reply ? 58 : 70, accuracy: 1)
      XCTAssertEqual(frame.maxX, surface.bounds.width - (reply ? 24 : 36), accuracy: 1)
      XCTAssertEqual(editor.string, reply ? r.body : c.comment.body)
    }
  }

  func testQuotedRootReplyIsInFooterAfterThreadRepliesAndUsesTwelvePointOuterGutter() async throws {
    let r = comment("reply", body: "Existing reply"), c = card(replies: [r]), state = GitHubPRDiscussionState()
    state.beginReply(c.comment, thread: c.thread, quote: true)
    let (_, root, surface) = try await host(cardView(c, collapse: .init(), state: state))
    let editor = try XCTUnwrap(find(PullRequestTextEditor.TextView.self, in: root)), scroll = try XCTUnwrap(editor.enclosingScrollView)
    let frame = surface.convert(scroll.bounds, from: scroll)
    XCTAssertEqual(frame.minX, 24, accuracy: 1); XCTAssertEqual(frame.maxX, surface.bounds.width - 24, accuracy: 1)
    XCTAssertEqual(editor.string, c.comment.quotedBody)
    XCTAssertGreaterThan(surface.bounds.height, 160)
    try render(root, "quoted-reply-footer")
  }

  func testMenuSurfaceUsesActualCSSControlBackgroundAndOverlayBorderAliases() async throws {
    var preferences = AppearancePreferences(); preferences.theme = "light"
    let menu = PullRequestCommentMenuSurface(options: [.edit, .quote, .delete], highlighted: nil, enabled: true,
      appearance: preferences, hover: { _ in }, choose: { _ in })
    let (_, root, _) = try await host(menu.frame(width: 160, height: 94), width: 160)
    let native = try XCTUnwrap(find(PullRequestCommentMenuSurface.Surface.self, in: root))
    XCTAssertEqual(native.surface, preferences.resolvedColors["controlBackgroundOpaque"].opacity(0.9).nativeColor)
    XCTAssertEqual(native.border, preferences.resolvedColors["border"].nativeColor)
  }

  func testMenuViewportStaysInsideSurfaceDuringZeroAndSubPaddingSizes() {
    _ = NSApplication.shared
    let surface = PullRequestCommentMenuSurface.Surface()
    surface.configure([.edit, .quote, .delete], highlighted: nil, enabled: true,
      appearance: .init(), hover: { _ in }, choose: { _ in })
    for size in [NSSize.zero, .init(width: 3, height: 4), .init(width: 8, height: 8),
      .init(width: 160, height: 94), .init(width: 0, height: 38),
      .init(width: 300, height: 94), .zero] {
      surface.setFrameSize(size); surface.needsLayout = true; surface.layoutSubtreeIfNeeded()
      let viewport = surface.scroll.frame
      XCTAssertFalse(viewport.isNull)
      XCTAssertTrue([viewport.minX, viewport.minY, viewport.width, viewport.height].allSatisfy(\.isFinite))
      XCTAssertGreaterThanOrEqual(viewport.minX, 0); XCTAssertGreaterThanOrEqual(viewport.minY, 0)
      XCTAssertLessThanOrEqual(viewport.maxX, size.width); XCTAssertLessThanOrEqual(viewport.maxY, size.height)
      XCTAssertEqual(viewport.width, max(0, size.width - 8))
      XCTAssertEqual(viewport.height, max(0, size.height - 8))
      XCTAssertEqual(surface.rows.map(\.item), [.edit, .quote, .delete])
    }
  }

  func testNativeMenuSurfaceUsesFiniteFramesAcrossResizing() throws {
    let diagnostics = ProcessInfo.processInfo.environment["SHIPIOS_COMMENT_LAYOUT_DIAGNOSTICS"] == "1"
    func checkpoint(_ message: String) { if diagnostics { print(message); fflush(stdout) } }
    _ = NSApplication.shared; checkpoint("before native surface")
    let surface = PullRequestCommentMenuSurface.Surface(frame: .init(x: 0, y: 0, width: 160, height: 94))
    checkpoint("after native surface")
    surface.configure([.edit, .quote, .delete], highlighted: nil, enabled: true, appearance: .init(), hover: { _ in }, choose: { _ in })
    checkpoint("after configure")
    for size in [NSSize(width: 160, height: 94), .init(width: 160, height: 38), .init(width: 300, height: 94)] {
      surface.setFrameSize(size); surface.layoutSubtreeIfNeeded(); checkpoint("after layout \(size)")
      XCTAssertEqual(surface.rows.count, 3)
      XCTAssertTrue(surface.rows.allSatisfy { $0.frame.width.isFinite && $0.frame.height.isFinite && $0.frame.width > 0 && $0.frame.height > 0 })
      XCTAssertLessThan(surface.document.frame.height, 100)
    }
  }
}
