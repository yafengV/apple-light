import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class PullRequestCommentMenuTests: XCTestCase {
  private final class TestWindow: NSWindow { override var isKeyWindow: Bool { true } }
  private let request = GitHubPullRequest(number: 42, url: "https://github.com/sample/project/pull/42", title: "Feature",
    isDraft: false, headRefName: "feature", baseRefName: "main", isCrossRepository: false)
  private struct CardFlow: View {
    let state: GitHubPRDiscussionState
    let card: GitHubPRCommentCard
    let collapse: GitHubPRCommentCollapseState
    let request: GitHubPullRequest
    var body: some View {
      TaskPullRequestCommentView(card: card, collapse: collapse, state: state, enabled: true, writable: true,
        mentionRequest: nil, open: { _ in }, submit: { _, _ in })
        .frame(width: 500)
        .background(PullRequestDiscussionDialogPresenter(state: state, request: request, writable: true, valid: { true },
          submitReview: {}, confirmReview: {}, deleteComment: { _ in }))
    }
  }
  private struct EditorFlow: View {
    let state: GitHubPRDiscussionState
    let comment: GitHubPRComment
    let action: PullRequestCommentMenuAction
    var body: some View {
      VStack {
        if let draft = state.drafts[comment.id] {
          TaskPullRequestCommentComposer(text: Binding(get: { state.drafts[comment.id]?.text ?? "" }, set: { state.drafts[comment.id]?.text = $0 }),
            label: "提交", focus: draft.focus, enabled: true, busy: false, cancel: {}, kind: action == .edit ? .edit : .reply(author: comment.author), submit: {})
        } else {
          PullRequestCommentActionMenu(options: [.edit, .quote], enabled: true) { selected in
            if selected == .edit { state.beginEdit(comment) } else { state.beginReply(comment, thread: nil, quote: true) }; return true
          }
        }
      }
    }
  }
  private final class Scope: NSView, WindowModalScope {
    var modalRoot: NSView { self }
    var modalScopeActive = true
    var blocksWorkspaceCommands: Bool { true }
  }
  private func reference() throws -> [String: Any] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/pr_comment_menu_reference.json")
    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  }
  private func comment(_ body: String = "  Original\n ", update: Bool = true, delete: Bool = true) -> GitHubPRComment {
    .init(id: "comment", kind: .issue, body: body, author: "author", authorType: "User",
      createdAt: "2026-09-29T10:00:00Z", url: nil, canUpdate: update, canDelete: delete)
  }
  private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
    (view as? T) ?? view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
  }
  private func settle(_ root: NSView) async throws {
    for _ in 0..<3 { root.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(50)) }
  }
  private func host<V: View>(_ view: V, width: CGFloat = 600, height: CGFloat = 400) async throws
    -> (NSWindow, NSHostingView<AnyView>, SettingsPopupMenuButton.Control) {
    _ = NSApplication.shared
    let window = TestWindow(contentRect: .init(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
    var preferences = AppearancePreferences(); preferences.theme = "light"
    let root = NSHostingView(rootView: AnyView(view.frame(width: width, height: height).environment(\.appAppearance, preferences)))
    window.contentView = root
    addTeardownBlock { @MainActor in window.contentView = nil; window.close() }
    try await settle(root)
    return (window, root, try XCTUnwrap(find(SettingsPopupMenuButton.Control.self, in: root)))
  }
  private func key(_ code: UInt16, _ window: NSWindow, text: String = "", flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 2,
      windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
  }
  private func surface(_ owner: SettingsPopupMenuButton.Coordinator) throws -> PullRequestCommentMenuSurface.Surface {
    try XCTUnwrap(find(PullRequestCommentMenuSurface.Surface.self, in: XCTUnwrap(owner.popup)))
  }
  private func render(_ view: NSView, _ name: String) throws {
    guard let folder = ProcessInfo.processInfo.environment["SHIPIOS_PR_COMMENT_MENU_RENDER_DIR"] else { return }
    view.layoutSubtreeIfNeeded()
    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
  }
  private func fixture() async throws -> (URL, GitHubPRDiscussionState) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("comment-menu-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    _ = try await GitReviewService.checked(["init", "-q", "-b", "feature"], at: root)
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/github_cli.py")
    let executable = root.appendingPathComponent(".git/gh-fixture")
    try FileManager.default.copyItem(at: source, to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let fields: [String: Any] = ["head": String(repeating: "a", count: 40), "viewer": "reviewer",
      "pullRequests": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))],
      "discussionTimeline": [["id": "comment", "__typename": "IssueComment", "body": "\u{FEFF} Original\n \u{FEFF}",
        "createdAt": "2026-09-29T10:00:00Z", "author": ["login": "reviewer", "__typename": "User"],
        "viewerCanUpdate": true, "viewerCanDelete": true]]]
    try JSONSerialization.data(withJSONObject: fields).write(to: root.appendingPathComponent(".git/github-fixture.json"))
    let state = GitHubPRDiscussionState(service: .init(executable: executable), coordinator: .init())
    await state.load(request, at: root, valid: { true }); XCTAssertNil(state.readError)
    addTeardownBlock { @MainActor in state.cancel() }; return (root, state)
  }
  private func writes(_ root: URL) throws -> [[String: Any]] {
    let path = root.appendingPathComponent(".git/github-requests.jsonl")
    return try String(contentsOf: path, encoding: .utf8).split(separator: "\n").compactMap {
      let value = try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
      guard let input = value?["input"] as? [String: Any], (input["query"] as? String)?.contains("mutation ShipiOSPRDiscussionMutation") == true else { return nil }
      return (input["variables"] as? [String: Any])?["input"] as? [String: Any]
    }
  }

  func testEightActualReferenceMenusMatchCapabilityOrderAndReplyRestrictions() throws {
    let facts = try reference(), cases = try XCTUnwrap(facts["cases"] as? [[String: Any]])
    XCTAssertEqual(facts["version"] as? String, "26.930.21537"); XCTAssertEqual(cases.count, 8)
    for sample in cases {
      let mask = try XCTUnwrap(sample["mask"] as? Int), c = comment(update: mask & 1 != 0, delete: mask & 4 != 0)
      let options = PullRequestCommentMenuAction.options(c, thread: nil, isReply: mask & 2 == 0)
      let expected = [(1, "Edit"), (2, "Quote reply"), (4, "Delete")].filter { mask & $0.0 != 0 }.map(\.1)
      let items = try XCTUnwrap(sample["items"] as? [[String: Any]])
      XCTAssertEqual(items.compactMap { $0["label"] as? String }, expected)
      XCTAssertEqual(options.map(\.id), [(1, "edit"), (2, "quote"), (4, "delete")].filter { mask & $0.0 != 0 }.map(\.1))
      XCTAssertEqual(sample["present"] as? Bool, !options.isEmpty)
      XCTAssertTrue(items.allSatisfy { $0["stopped"] as? Int == 1 })
      if let delete = items.first(where: { $0["label"] as? String == "Delete" }) { XCTAssertEqual(delete["tone"] as? String, "danger") }
    }
    let thread = GitHubPRReviewThread(id: "thread", path: "main.swift", line: 1, originalLine: 1,
      diffHunk: "", isResolved: false, isOutdated: false, canReply: false, canResolve: true, canUnresolve: false, comments: [comment()])
    XCTAssertEqual(PullRequestCommentMenuAction.options(comment(), thread: thread, isReply: false), [.edit, .delete])
  }

  func testActualWorkerTrimAndQuoteFactsPreserveInternalLinesAndNonECMAScriptSpaces() throws {
    let facts = try reference(), trims = try XCTUnwrap(facts["trimCases"] as? [[String: Any]])
    XCTAssertEqual(trims.count, 28)
    for item in trims {
      let raw = try XCTUnwrap(item["value"] as? String), point = try XCTUnwrap(item["point"] as? Int)
      XCTAssertEqual(JavaScriptText.trimmed(raw), item["trimmed"] as? String, "U+" + String(point, radix: 16))
      let scalar = try XCTUnwrap(UnicodeScalar(point)), space = String(scalar)
      XCTAssertEqual(JavaScriptText.trimmed(space).isEmpty, item["empty"] as? Bool)
      XCTAssertEqual(GitHubPRReviewDecision.comment.accepts(space), item["empty"] as? Bool == false)
    }
    let quotes = try XCTUnwrap(facts["quotes"] as? [[String: Any]]); XCTAssertEqual(quotes.count, 10)
    for sample in quotes {
      let c = comment(try XCTUnwrap(sample["raw"] as? String))
      XCTAssertEqual(c.displayBody.isEmpty, sample["opened"] as? Bool == false)
      if sample["opened"] as? Bool == true {
        XCTAssertEqual(c.displayBody, sample["displayBody"] as? String); XCTAssertEqual(c.quotedBody, sample["draft"] as? String)
        let state = GitHubPRDiscussionState(); state.beginReply(c, thread: nil, quote: true)
        XCTAssertEqual(state.drafts[c.id]?.text, sample["draft"] as? String)
        state.beginEdit(c); XCTAssertEqual(state.drafts[c.id]?.text, c.body, "Editing must retain the raw source")
      }
    }
  }

  func testNativeVectorBoundsMatchReferenceAndActuallyPaintInk() throws {
    let icons = try XCTUnwrap(reference()["icons"] as? [[String: Any]]); XCTAssertEqual(icons.count, 4)
    for item in icons {
      let id = try XCTUnwrap(item["id"] as? String), expected = try XCTUnwrap(item["bounds"] as? [String: Double])
      let rect = try XCTUnwrap(PullRequestCommentMenuArtwork.bounds(id))
      XCTAssertEqual(rect.minX, try XCTUnwrap(expected["x"]), accuracy: 0.001)
      XCTAssertEqual(rect.minY, try XCTUnwrap(expected["y"]), accuracy: 0.001)
      XCTAssertEqual(rect.width, try XCTUnwrap(expected["width"]), accuracy: 0.001)
      XCTAssertEqual(rect.height, try XCTUnwrap(expected["height"]), accuracy: 0.001)
      let image = NSImage(size: .init(width: 16, height: 16)); image.lockFocus()
      PullRequestCommentMenuArtwork.draw(id, in: .init(x: 0, y: 0, width: 16, height: 16), color: .black, flipped: false); image.unlockFocus()
      let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
      let ink = (0..<bitmap.pixelsWide).reduce(0) { total, x in total + (0..<bitmap.pixelsHigh).filter { bitmap.colorAt(x: x, y: $0)?.alphaComponent ?? 0 > 0.1 }.count }
      XCTAssertGreaterThan(ink, 5)
    }
  }

  func testMenuUsesOwningWindowTrailingAlignmentAndActualNativeRows() async throws {
    var selections: [PullRequestCommentMenuAction] = []
    let (window, root, button) = try await host(PullRequestCommentActionMenu(options: [.edit, .quote, .delete], enabled: true) { selections.append($0); return true })
    let owner = try XCTUnwrap(button.owner); XCTAssertEqual(button.bounds.size, .init(width: 24, height: 24))
    XCTAssertTrue(button.accessibilityPerformPress()); try await settle(root)
    let popup = try XCTUnwrap(owner.popup), form = try surface(owner)
    XCTAssertTrue(popup.window === window); XCTAssertNil(window.attachedSheet)
    XCTAssertEqual(popup.frame.width, 160); XCTAssertEqual(popup.frame.height, 8 + 3 * 200 / 7, accuracy: 0.01)
    XCTAssertEqual(popup.convert(popup.bounds, to: nil).maxX, button.convert(button.bounds, to: nil).maxX, accuracy: 0.01)
    XCTAssertEqual(form.rows.map(\.title), ["编辑", "引用回复", "删除"])
    XCTAssertEqual(form.rows.last?.foreground, .systemRed); XCTAssertEqual(form.layer?.cornerRadius, 16)
    XCTAssertEqual(form.scroll.frame.minX, 4); XCTAssertEqual(form.rows[0].font?.pointSize, 13)
    XCTAssertTrue(window.firstResponder === form.rows[0], "Keyboard entry focuses the first action")
    try render(form, "three-actions"); XCTAssertTrue(form.rows[1].accessibilityPerformPress())
    XCTAssertEqual(selections, [.quote]); XCTAssertNil(owner.popup); try await settle(root)
    XCTAssertFalse(window.isVisible)
  }

  func testKeyboardClampsTabAndTypeaheadAndEscapeReturnsTrigger() async throws {
    let (window, root, button) = try await host(PullRequestCommentActionMenu(options: [.edit, .quote, .delete], enabled: true) { _ in XCTFail("Navigation must not select"); return true })
    let owner = try XCTUnwrap(button.owner); owner.toggle(button, keyboard: true); try await settle(root)
    XCTAssertTrue(owner.handle(try key(126, window), button: button)); XCTAssertEqual(owner.parent.menu.highlightedID, "edit")
    XCTAssertTrue(owner.handle(try key(119, window), button: button)); try await settle(root)
    XCTAssertEqual(owner.parent.menu.highlightedID, "delete"); XCTAssertTrue(window.firstResponder === (try surface(owner)).rows.last)
    XCTAssertTrue(owner.handle(try key(125, window), button: button)); XCTAssertEqual(owner.parent.menu.highlightedID, "delete")
    XCTAssertTrue(owner.handle(try key(48, window), button: button)); XCTAssertTrue(owner.parent.menu.presented)
    XCTAssertTrue(owner.handle(try key(48, window, flags: .shift), button: button)); XCTAssertTrue(owner.parent.menu.presented)
    XCTAssertTrue(owner.handle(try key(0, window, text: "引"), button: button)); XCTAssertEqual(owner.parent.menu.highlightedID, "quote")
    XCTAssertTrue(owner.handle(try key(53, window), button: button)); try await settle(root)
    XCTAssertNil(owner.popup); XCTAssertTrue(window.firstResponder === button)
  }

  func testNarrowViewportScrollsLastActionIntoViewWithoutClippingKeyboardFocus() async throws {
    var selected: PullRequestCommentMenuAction?
    let (window, root, button) = try await host(PullRequestCommentActionMenu(options: [.edit, .quote, .delete], enabled: true) { selected = $0; return true }, width: 180, height: 140)
    let owner = try XCTUnwrap(button.owner); owner.toggle(button, keyboard: true); try await settle(root)
    let popup = try XCTUnwrap(owner.popup), form = try surface(owner)
    XCTAssertLessThan(popup.frame.height, 8 + 3 * 200 / 7)
    XCTAssertTrue(root.bounds.insetBy(dx: 6, dy: 6).contains(popup.frame)); try render(form, "narrow-first")
    XCTAssertTrue(owner.handle(try key(119, window), button: button)); try await settle(root)
    let last = try XCTUnwrap(form.rows.last)
    XCTAssertTrue(window.firstResponder === last); XCTAssertGreaterThan(form.scroll.contentView.bounds.minY, 0)
    XCTAssertTrue(form.scroll.contentView.bounds.intersects(last.frame)); try render(form, "narrow-last")
    XCTAssertTrue(owner.handle(try key(36, window), button: button)); XCTAssertEqual(selected, .delete); XCTAssertNil(owner.popup)
  }

  func testBlurDoesNotDismissButOutsideClickAndWindowCloseDo() async throws {
    let (window, root, button) = try await host(PullRequestCommentActionMenu(options: [.edit, .quote], enabled: true) { _ in true })
    let owner = try XCTUnwrap(button.owner); owner.toggle(button, keyboard: false); try await settle(root)
    XCTAssertNil(owner.parent.menu.highlightedID)
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
    XCTAssertNotNil(owner.popup); XCTAssertTrue(owner.parent.menu.presented)
    let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .init(x: 1, y: 1), modifierFlags: [], timestamp: 1,
      windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    XCTAssertFalse(owner.handle(event, button: button)); XCTAssertNil(owner.popup)
    owner.toggle(button, keyboard: true); NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
    XCTAssertNil(owner.popup); XCTAssertFalse(owner.parent.menu.presented)
  }

  func testUnmountAndWindowModalRejectLateNativeActionsAndForeignKeys() async throws {
    var selections = 0
    let (window, root, button) = try await host(PullRequestCommentActionMenu(options: [.edit, .quote, .delete], enabled: true) { _ in selections += 1; return true })
    let (other, _, _) = try await host(PullRequestCommentActionMenu(options: [.quote], enabled: true) { _ in true })
    let owner = try XCTUnwrap(button.owner); owner.toggle(button, keyboard: true); try await settle(root)
    XCTAssertFalse(owner.handle(try key(53, other), button: button)); XCTAssertNotNil(owner.popup)
    let row = try surface(owner).rows[0], scope = Scope(frame: .init(x: 0, y: 0, width: 100, height: 100))
    root.addSubview(scope); WindowModalInteraction.install(scope, in: window)
    XCTAssertFalse(row.accessibilityPerformPress()); XCTAssertFalse(owner.handle(try key(36, window), button: button))
    XCTAssertEqual(selections, 0); XCTAssertNil(owner.popup)
    WindowModalInteraction.remove(scope, from: window); scope.removeFromSuperview()
    owner.toggle(button, keyboard: true); try await settle(root); let stale = try surface(owner).rows[0]
    root.rootView = AnyView(Text("Removed")); try await settle(root)
    XCTAssertNil(owner.popup); XCTAssertFalse(stale.accessibilityPerformPress()); owner.choose("edit", button: button)
    XCTAssertEqual(selections, 0)
  }

  func testEditAndQuoteSelectionHandFocusToNewNativeEditorWithoutLateRestore() async throws {
    for action in [PullRequestCommentMenuAction.edit, .quote] {
      let state = GitHubPRDiscussionState(), c = comment()
      let content = EditorFlow(state: state, comment: c, action: action)
      let (window, root, button) = try await host(content), owner = try XCTUnwrap(button.owner)
      owner.toggle(button, keyboard: true); try await settle(root); owner.choose(action.id, button: button); try await settle(root)
      let editor = try XCTUnwrap(find(PullRequestTextEditor.TextView.self, in: root))
      XCTAssertTrue(window.firstResponder === editor); XCTAssertEqual(editor.string, action == .edit ? c.body : c.quotedBody)
      XCTAssertNil(owner.popup); XCTAssertFalse(button.active)
      try await settle(root); XCTAssertTrue(window.firstResponder === editor)
    }
  }

  func testDisabledAndRemovedOptionsCannotApplyStaleChoice() async throws {
    var selections = 0
    let state = PullRequestCommentMenuState(options: [.edit, .quote, .delete])
    state.open(keyboard: true); state.edge(last: true); state.configure([.quote]); XCTAssertEqual(state.highlightedID, "quote")
    state.configure([]); XCTAssertFalse(state.presented)
    let (window, root, button) = try await host(PullRequestCommentActionMenu(options: [.edit], enabled: false) { _ in selections += 1; return true })
    XCTAssertFalse(button.accessibilityPerformPress()); XCTAssertNil(button.owner?.popup)
    root.rootView = AnyView(PullRequestCommentActionMenu(options: [.edit], enabled: true) { _ in selections += 1; return true }.frame(width: 600, height: 400))
    try await settle(root); let current = try XCTUnwrap(find(SettingsPopupMenuButton.Control.self, in: root)), owner = try XCTUnwrap(current.owner)
    owner.toggle(current, keyboard: true); try await settle(root)
    root.rootView = AnyView(PullRequestCommentActionMenu(options: [.quote], enabled: true) { _ in selections += 1; return true }.frame(width: 600, height: 400))
    try await settle(root); owner.choose("edit", button: current); XCTAssertEqual(selections, 0)
    XCTAssertTrue(owner.handle(try key(53, window), button: current)); XCTAssertNil(owner.popup)
  }

  func testActualCollapsedCardMenuDoesNotToggleAndEditReplyExpandWithCorrectDraftFocus() async throws {
    for action in [PullRequestCommentMenuAction.edit, .quote] {
      let (_, state) = try await fixture(), c = try XCTUnwrap(state.snapshot?.comments.first), card = GitHubPRCommentCard(comment: c, thread: nil)
      let collapse = GitHubPRCommentCollapseState(); collapse.toggle(card, all: false, cards: [card], drafts: [:])
      let (window, root, button) = try await host(CardFlow(state: state, card: card, collapse: collapse, request: request))
      let owner = try XCTUnwrap(button.owner); owner.toggle(button, keyboard: true); try await settle(root)
      XCTAssertTrue(collapse.isCollapsed(card, drafts: state.drafts)); XCTAssertTrue(state.drafts.isEmpty)
      let row = try XCTUnwrap(surface(owner).rows.first { $0.item == action }); XCTAssertTrue(row.accessibilityPerformPress())
      try await settle(root); XCTAssertFalse(collapse.isCollapsed(card, drafts: state.drafts)); XCTAssertNil(owner.popup)
      let editor = try XCTUnwrap(find(PullRequestTextEditor.TextView.self, in: root))
      XCTAssertEqual(editor.string, action == .edit ? c.body : c.quotedBody); XCTAssertTrue(window.firstResponder === editor)
      XCTAssertFalse(button.active); state.cancelDraft(c.id); try await settle(root)
      XCTAssertNotNil(find(SettingsPopupMenuButton.Control.self, in: root)); XCTAssertFalse(collapse.isCollapsed(card, drafts: state.drafts))
    }
  }

  func testActualCardDeleteOpensOwnedDialogAndCancelRestoresLiveTriggerWithoutCollapsing() async throws {
    let (_, state) = try await fixture(), c = try XCTUnwrap(state.snapshot?.comments.first), card = GitHubPRCommentCard(comment: c, thread: nil)
    let collapse = GitHubPRCommentCollapseState()
    let (window, root, button) = try await host(CardFlow(state: state, card: card, collapse: collapse, request: request))
    let owner = try XCTUnwrap(button.owner); owner.toggle(button, keyboard: true); try await settle(root)
    XCTAssertTrue(try surface(owner).rows.last!.accessibilityPerformPress()); try await settle(root)
    let dialog = try XCTUnwrap(find(PullRequestDiscussionDialogPresenter.Surface.self, in: root))
    XCTAssertNil(owner.popup); XCTAssertNil(window.attachedSheet); XCTAssertEqual(state.deleteTarget?.id, c.id)
    XCTAssertFalse(collapse.isCollapsed(card, drafts: state.drafts)); XCTAssertTrue(WindowModalInteraction.blocksCommands(in: window))
    XCTAssertFalse(button.acceptsFirstResponder); XCTAssertTrue(dialog.cancel.accessibilityPerformPress()); try await settle(root)
    XCTAssertNil(state.deleteTarget); XCTAssertTrue(button.acceptsFirstResponder); XCTAssertTrue(window.firstResponder === button)
  }

  func testActualCardRechecksLatestPermissionsBeforeStaleMenuSelection() async throws {
    let (directory, state) = try await fixture(), c = try XCTUnwrap(state.snapshot?.comments.first), card = GitHubPRCommentCard(comment: c, thread: nil)
    let (_, root, button) = try await host(CardFlow(state: state, card: card, collapse: .init(), request: request))
    let owner = try XCTUnwrap(button.owner); owner.toggle(button, keyboard: true); try await settle(root)
    let path = directory.appendingPathComponent(".git/github-fixture.json")
    var data = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
    var comments = try XCTUnwrap(data["discussionTimeline"] as? [[String: Any]])
    comments[0]["viewerCanUpdate"] = false; comments[0]["viewerCanDelete"] = false; data["discussionTimeline"] = comments
    try JSONSerialization.data(withJSONObject: data).write(to: path); await state.load(request, at: directory, valid: { true })
    owner.choose("edit", button: button); owner.choose("delete", button: button)
    XCTAssertTrue(state.drafts.isEmpty); XCTAssertNil(state.deleteTarget); XCTAssertTrue(try writes(directory).isEmpty)
  }

  func testServiceRejectsBOMOnlyAndPreservesNextLineCharactersWhileTrimmingBOM() async throws {
    let (directory, state) = try await fixture()
    for body in ["\u{FEFF}", " \n\u{FEFF}"] {
      XCTAssertTrue(state.start(.post(body: body, thread: nil), request: request, at: directory, valid: { true }, writable: { true }))
      await state.operation?.value; XCTAssertNotNil(state.message(for: .general)); XCTAssertTrue(try writes(directory).isEmpty)
    }
    let body = "\u{FEFF}\u{85}Reply\u{85}\u{FEFF}"
    XCTAssertTrue(state.start(.post(body: body, thread: nil), request: request, at: directory, valid: { true }, writable: { true }))
    await state.operation?.value; XCTAssertNil(state.message(for: .general))
    XCTAssertEqual(try writes(directory).map { $0["body"] as? String }, ["\u{85}Reply\u{85}"])
    XCTAssertEqual(state.snapshot?.comments.last?.body, "\u{85}Reply\u{85}")
  }
}
