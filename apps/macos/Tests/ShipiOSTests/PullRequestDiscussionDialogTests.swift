import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class PullRequestDiscussionDialogTests: XCTestCase {
  private let request = GitHubPullRequest(number: 42, url: "https://github.com/sample/project/pull/42",
    title: "Feature", isDraft: false, headRefName: "feature", baseRefName: "main", isCrossRepository: false)
  private final class TestWindow: NSWindow { override var isKeyWindow: Bool { true } }
  private func fixture(_ extra: [String: Any] = [:]) async throws -> (URL, GitHubPRDiscussionState) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("discussion-dialog-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    _ = try await GitReviewService.checked(["init", "-q", "-b", "feature"], at: root)
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/github_cli.py")
    let executable = root.appendingPathComponent(".git/gh-fixture")
    try FileManager.default.copyItem(at: source, to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let comments: [[String: Any]] = ["one", "two"].map { id in
      ["id": id, "__typename": "IssueComment", "body": "Private comment " + id,
       "createdAt": "2026-09-29T10:00:00Z", "author": ["login": "reviewer", "__typename": "User"],
       "viewerCanUpdate": true, "viewerCanDelete": true]
    }
    var fields: [String: Any] = ["head": String(repeating: "a", count: 40), "viewer": "reviewer",
      "pullRequests": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))], "discussionTimeline": comments]
    extra.forEach { fields[$0.key] = $0.value }
    try JSONSerialization.data(withJSONObject: fields).write(to: root.appendingPathComponent(".git/github-fixture.json"))
    let state = GitHubPRDiscussionState(service: .init(executable: executable), coordinator: .init())
    await state.load(request, at: root, valid: { true }); XCTAssertNil(state.readError)
    return (root, state)
  }
  private func host(_ state: GitHubPRDiscussionState, width: CGFloat = 900, writable: Bool = true,
    valid: @escaping () -> Bool = { true }, source: NSTextView? = nil, submit: @escaping () -> Void = {}, confirm: @escaping () -> Void = {},
    delete: @escaping (GitHubPRComment) -> Void = { _ in }, notice: @escaping (String) -> Void = { _ in }) throws
    -> (NSWindow, NSView, WindowDialogHost.Anchor, PullRequestDiscussionDialogPresenter.Coordinator, PullRequestDiscussionDialogPresenter.Surface) {
    let window = TestWindow(contentRect: .init(x: 0, y: 0, width: width, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
    let root = NSView(frame: .init(x: 0, y: 0, width: width, height: 700)); window.contentView = root
    if let source { root.addSubview(source); window.makeFirstResponder(source) }
    let presenter = PullRequestDiscussionDialogPresenter(state: state, request: request, writable: writable, valid: valid,
      submitReview: submit, confirmReview: confirm, deleteComment: delete, reportDeleteError: notice)
    let owner = presenter.makeCoordinator(), anchor = WindowDialogHost.Anchor(frame: .init(x: 700, y: 50, width: 1, height: 1))
    anchor.host = owner.host; root.addSubview(anchor); owner.host.present(anchor); root.layoutSubtreeIfNeeded()
    let form = try XCTUnwrap(owner.host.surface as? PullRequestDiscussionDialogPresenter.Surface)
    addTeardownBlock { @MainActor in owner.stop(); window.contentView = nil; window.close(); state.cancel() }
    return (window, root, anchor, owner, form)
  }
  private func key(_ code: UInt16, _ window: NSWindow, flags: NSEvent.ModifierFlags = [], repeatKey: Bool = false) throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: code == 13 ? "w" : "",
      charactersIgnoringModifiers: code == 13 ? "w" : "", isARepeat: repeatKey, keyCode: code))
  }
  private func start(_ state: GitHubPRDiscussionState, _ action: GitHubPRDiscussionAction, _ root: URL) {
    XCTAssertTrue(state.start(action, request: request, at: root, valid: { true }, writable: { true }))
  }
  private func writes(_ root: URL) throws -> [[String: Any]] {
    let path = root.appendingPathComponent(".git/github-requests.jsonl")
    guard FileManager.default.fileExists(atPath: path.path) else { return [] }
    return try String(contentsOf: path).split(separator: "\n").compactMap {
      let value = try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
      guard let input = value?["input"] as? [String: Any], (input["query"] as? String)?.contains("mutation ShipiOSPRDiscussionMutation") == true else { return nil }
      return input["variables"] as? [String: Any]
    }
  }
  private func render(_ root: NSView, _ name: String) throws {
    guard let path = ProcessInfo.processInfo.environment["SHIPIOS_PR_DIALOG_RENDER_DIR"] else { return }
    root.layoutSubtreeIfNeeded()
    let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds)); root.cacheDisplay(in: root.bounds, to: bitmap)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path).appendingPathComponent(name + ".png"))
  }

  func testActualReferenceComponentContractsIncludeValidationAndFailureRetention() throws {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/pr_discussion_dialog_reference.json")
    let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
    XCTAssertEqual(value["version"] as? String, "26.930.21537")
    let reviews = try XCTUnwrap(value["reviewCases"] as? [[String: Any]]), deletes = try XCTUnwrap(value["deleteCases"] as? [[String: Any]])
    XCTAssertEqual(reviews.count, 6); XCTAssertEqual(deletes.count, 3)
    for item in reviews {
      XCTAssertEqual(item["width"] as? Int, 600); XCTAssertEqual(item["rows"] as? Int, 4)
      XCTAssertEqual(item["autoFocus"] as? Bool, true); XCTAssertEqual(item["closeButton"] as? Bool, false)
      XCTAssertEqual(item["confirmDisabled"] as? Bool, false)
      XCTAssertEqual(item["textareaDisabled"] as? Bool, item["pending"] as? Bool)
      let result = try XCTUnwrap(item["result"] as? [String: Any]), name = try XCTUnwrap(item["name"] as? String)
      XCTAssertEqual(result["open"] as? Bool, !["empty-approve", "trimmed-comment"].contains(name))
      if name.hasPrefix("empty-") && name != "empty-approve" { XCTAssertEqual(item["mutationCount"] as? Int, 0); XCTAssertNotNil(result["error"] as? String) }
      if name == "failure" { XCTAssertEqual(result["decision"] as? String, "request_changes"); XCTAssertEqual(result["body"] as? String, "Review") }
    }
    for item in deletes {
      XCTAssertEqual(item["width"] as? Int, 520); XCTAssertEqual(item["sectionCount"] as? Int, 2)
      XCTAssertEqual(item["confirmColor"] as? String, "dangerSolid"); XCTAssertEqual(item["closeButton"] as? Bool, false)
      XCTAssertEqual(item["cancelDisabled"] as? Bool, item["pending"] as? Bool)
      if item["name"] as? String == "failure" { XCTAssertEqual(item["closes"] as? Int, 0); XCTAssertEqual(item["alerts"] as? [String], ["fixture failure"]) }
    }
  }

  func testReviewOwnsFullWindowAndInitiallyFocusesTextareaWithHorizontalRadios() async throws {
    let (_, state) = try await fixture(); state.openReview()
    let (window, root, anchor, _, form) = try host(state)
    XCTAssertTrue(form.superview === root); XCTAssertFalse(form.isDescendant(of: anchor)); XCTAssertNil(window.attachedSheet)
    XCTAssertEqual(form.bounds.size, root.bounds.size); XCTAssertEqual(form.dialogFrame.width, 600)
    XCTAssertTrue(window.firstResponder === form.editor); XCTAssertEqual(form.editorHeight, 96)
    XCTAssertEqual(Set(form.decisions.map { $0.frame.minY }).count, 1); XCTAssertEqual(form.focusTargets.count, 4)
    XCTAssertEqual(form.accessibilitySubrole(), .dialog); XCTAssertTrue(form.isAccessibilityModal())
    XCTAssertTrue(WindowModalInteraction.blocksCommands(in: window)); XCTAssertTrue(WindowModalInteraction.allowsTextEditing(in: window))
    XCTAssertFalse(window.isVisible); try render(root, "review-in-window")
  }

  func testEmptySubmitShowsSpecificValidationAndApproveAllowsBlank() async throws {
    let (directory, state) = try await fixture(); state.openReview(); var submissions = 0
    let (_, root, _, owner, form) = try host(state, submit: { submissions += 1 })
    XCTAssertTrue(form.submit.isEnabled); XCTAssertTrue(form.submit.accessibilityPerformPress())
    XCTAssertEqual(state.message(for: .review), "提交审查前请添加评论。"); XCTAssertFalse(form.errorScroll.isHidden)
    owner.select(.requestChanges, in: form); state.reviewBody = "  \n"
    XCTAssertTrue(form.submit.accessibilityPerformPress()); XCTAssertEqual(state.message(for: .review), "要求修改前请添加评论。")
    try render(root, "review-validation")
    owner.select(.approve, in: form); XCTAssertEqual(form.editor.placeholder, "可选评论")
    XCTAssertTrue(form.submit.accessibilityPerformPress()); XCTAssertEqual(submissions, 1); XCTAssertNil(state.message(for: .review))
    XCTAssertTrue(try writes(directory).isEmpty)
  }

  func testTabUsesSelectedRadioAndArrowsWrapWithoutSubmitting() async throws {
    let (_, state) = try await fixture(); state.openReview(); var submissions = 0
    let (window, _, _, owner, form) = try host(state, submit: { submissions += 1 })
    XCTAssertTrue(owner.host.handle(try key(48, window, flags: .shift))); XCTAssertTrue(window.firstResponder === form.decisions[0])
    XCTAssertTrue(owner.host.handle(try key(123, window))); XCTAssertEqual(state.reviewDecision, .requestChanges)
    XCTAssertTrue(window.firstResponder === form.decisions[2]); XCTAssertTrue(owner.host.handle(try key(124, window)))
    XCTAssertEqual(state.reviewDecision, .comment); XCTAssertEqual(submissions, 0)
    XCTAssertTrue(owner.host.handle(try key(48, window))); XCTAssertTrue(window.firstResponder === form.editor)
    XCTAssertTrue(owner.host.handle(try key(48, window))); XCTAssertTrue(window.firstResponder === form.cancel)
    XCTAssertTrue(owner.host.handle(try key(48, window))); XCTAssertTrue(window.firstResponder === form.submit)
    XCTAssertTrue(owner.host.handle(try key(48, window))); XCTAssertTrue(window.firstResponder === form.decisions[0])
  }

  func testNativeEditingNewlineUndoAndCancellationPreserveDraft() async throws {
    let (_, state) = try await fixture(); state.openReview()
    let (window, _, anchor, owner, form) = try host(state)
    form.editor.insertText("Review", replacementRange: .init(location: 0, length: 0))
    XCTAssertEqual(state.reviewBody, "Review")
    XCTAssertFalse(owner.host.handle(try key(36, window))); form.editor.insertNewline(nil)
    XCTAssertEqual(state.reviewBody, "Review\n")
    form.editor.breakUndoCoalescing(); form.editor.insertText("Extra", replacementRange: form.editor.selectedRange())
    XCTAssertEqual(state.reviewBody, "Review\nExtra")
    let undo = try XCTUnwrap(form.editor.undoManager); XCTAssertTrue(undo.canUndo); undo.undo()
    XCTAssertEqual(state.reviewBody, form.editor.string); XCTAssertFalse(state.reviewBody.contains("Extra"))
    undo.redo(); XCTAssertEqual(state.reviewBody, form.editor.string); XCTAssertTrue(state.reviewBody.contains("Extra"))
    owner.select(.requestChanges, in: form); owner.host.dismiss()
    XCTAssertFalse(state.showingReview); XCTAssertEqual(state.reviewBody, "Review\nExtra"); XCTAssertEqual(state.reviewDecision, .requestChanges)
    state.openReview(); owner.host.present(anchor)
    let reopened = try XCTUnwrap(owner.host.surface as? PullRequestDiscussionDialogPresenter.Surface)
    XCTAssertEqual(reopened.editor.string, state.reviewBody); XCTAssertTrue(window.firstResponder === reopened.editor)
    XCTAssertFalse(form.submit.accessibilityPerformPress())
  }

  func testMarkedTextStaysNativeUntilCommittedAndBlocksFormCommands() async throws {
    let (_, state) = try await fixture(); state.openReview(); var submissions = 0
    let (window, _, _, owner, form) = try host(state, submit: { submissions += 1 })
    form.editor.setMarkedText("中文", selectedRange: .init(location: 2, length: 0), replacementRange: .init(location: 0, length: 0))
    XCTAssertTrue(form.editor.hasMarkedText()); XCTAssertEqual(state.reviewBody, "")
    for code: UInt16 in [36, 48, 53] { XCTAssertFalse(owner.host.handle(try key(code, window, flags: code == 36 ? .command : []))) }
    owner.submit(form); XCTAssertEqual(submissions, 0); XCTAssertTrue(state.showingReview)
    owner.configure(form); XCTAssertTrue(form.editor.hasMarkedText()); XCTAssertEqual(form.editor.string, "中文")
    form.editor.unmarkText(); owner.textDidChange(.init(name: NSText.didChangeNotification, object: form.editor))
    XCTAssertEqual(state.reviewBody, "中文"); XCTAssertTrue(owner.host.handle(try key(36, window, flags: .control)))
    XCTAssertEqual(submissions, 1)
    XCTAssertTrue(owner.host.handle(try key(36, window, flags: .command, repeatKey: true))); XCTAssertEqual(submissions, 1)
  }

  func testCapturedReviewSubmissionLocksFormAndSuccessResetsDraft() async throws {
    let (directory, state) = try await fixture(["discussionMutationDelay": 0.15]); state.openReview(); state.reviewBody = "  Review  "
    let (window, _, anchor, owner, form) = try host(state, submit: { self.start(state, state.reviewAction!, directory) })
    XCTAssertTrue(owner.host.handle(try key(36, window, flags: .command))); owner.configure(form)
    XCTAssertTrue(state.busy); XCTAssertFalse(form.editor.isEditable); XCTAssertTrue(form.submit.loading)
    XCTAssertFalse(form.cancel.accessibilityPerformPress()); XCTAssertFalse(form.submit.accessibilityPerformPress())
    XCTAssertFalse(form.decisions[1].accessibilityPerformPress()); owner.host.dismiss()
    XCTAssertTrue(owner.host.handle(try key(53, window))); XCTAssertTrue(state.showingReview)
    await state.operation?.value; owner.host.update(anchor)
    XCTAssertFalse(state.showingReview); XCTAssertEqual(state.reviewBody, ""); XCTAssertEqual(state.reviewDecision, .comment)
    XCTAssertNil(owner.host.surface)
    let calls = try writes(directory); XCTAssertEqual(calls.count, 1)
    let input = try XCTUnwrap(calls.first?["input"] as? [String: Any]); XCTAssertEqual(input["body"] as? String, "Review")
    XCTAssertEqual(input["event"] as? String, "COMMENT"); XCTAssertEqual(input["commitOID"] as? String, String(repeating: "a", count: 40))
  }

  func testReviewFailureRetainsDecisionBodyAndShowsInlineError() async throws {
    let (directory, state) = try await fixture(["discussionMutationGraphQLError": true]); state.openReview()
    state.reviewBody = "Review"; state.reviewDecision = .requestChanges
    let (_, root, _, owner, form) = try host(state, submit: { self.start(state, state.reviewAction!, directory) })
    XCTAssertTrue(form.submit.accessibilityPerformPress()); await state.operation?.value; owner.configure(form)
    XCTAssertTrue(state.showingReview); XCTAssertEqual(state.reviewBody, "Review"); XCTAssertEqual(state.reviewDecision, .requestChanges)
    XCTAssertFalse(form.errorScroll.isHidden); XCTAssertFalse(form.error.stringValue.isEmpty); XCTAssertTrue(form.submit.isEnabled)
    XCTAssertEqual(try writes(directory).count, 1); try render(root, "review-failure")
  }

  func testDeleteContainsOnlyReferenceFieldsAndHasDangerConfirmation() async throws {
    let (_, state) = try await fixture(); state.deleteTarget = try XCTUnwrap(state.snapshot?.comment("one"))
    let (window, root, _, owner, form) = try host(state)
    XCTAssertEqual(form.dialogFrame.width, 520); XCTAssertTrue(window.firstResponder === form.cancel)
    XCTAssertEqual(form.focusTargets.count, 2); XCTAssertTrue(form.scroll.isHidden); XCTAssertTrue(form.errorScroll.isHidden)
    XCTAssertEqual(form.submit.style, .danger); XCTAssertEqual(form.accessibilityChildren()?.count, 3)
    XCTAssertFalse(form.subviews.compactMap { ($0 as? NSTextField)?.stringValue }.contains("Private comment one"))
    XCTAssertTrue(owner.host.handle(try key(48, window))); XCTAssertTrue(window.firstResponder === form.submit)
    XCTAssertTrue(owner.host.handle(try key(48, window))); XCTAssertTrue(window.firstResponder === form.cancel)
    try render(root, "delete-confirmation")
  }

  func testDeleteFailureUsesSingleToastAndKeepsDialogThenRetryCloses() async throws {
    let (directory, state) = try await fixture(["discussionMutationGraphQLError": true]); state.deleteTarget = try XCTUnwrap(state.snapshot?.comment("one"))
    var notices: [String] = []
    let (_, _, anchor, owner, form) = try host(state, delete: { self.start(state, .delete(id: $0.id, kind: $0.kind), directory) }, notice: { notices.append($0) })
    XCTAssertTrue(form.submit.accessibilityPerformPress()); await state.operation?.value; owner.configure(form)
    owner.configure(form); try await Task.sleep(for: .milliseconds(30))
    XCTAssertEqual(notices.count, 1); XCTAssertTrue(form.errorScroll.isHidden); XCTAssertNotNil(state.deleteTarget)
    let path = directory.appendingPathComponent(".git/github-fixture.json")
    var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
    fields["discussionMutationGraphQLError"] = false; try JSONSerialization.data(withJSONObject: fields).write(to: path)
    XCTAssertTrue(form.submit.accessibilityPerformPress()); owner.configure(form); XCTAssertFalse(form.cancel.isEnabled)
    await state.operation?.value; owner.host.update(anchor)
    XCTAssertNil(state.deleteTarget); XCTAssertNil(owner.host.surface); XCTAssertNil(state.snapshot?.comment("one"))
    XCTAssertNotNil(state.snapshot?.comment("two")); XCTAssertEqual(try writes(directory).count, 2)
  }

  func testReplacedDeleteTargetRejectsStaleCallbacksAndUnmountCleansScope() async throws {
    let (directory, state) = try await fixture(); state.deleteTarget = try XCTUnwrap(state.snapshot?.comment("one"))
    var targets: [String] = []
    let (window, _, anchor, owner, old) = try host(state, delete: { targets.append($0.id) })
    state.deleteTarget = try XCTUnwrap(state.snapshot?.comment("two")); owner.host.present(anchor)
    let replacement = try XCTUnwrap(owner.host.surface as? PullRequestDiscussionDialogPresenter.Surface)
    XCTAssertFalse(old.submit.accessibilityPerformPress()); old.submit.activate?(); old.cancel.activate?()
    XCTAssertEqual(state.deleteTarget?.id, "two"); XCTAssertTrue(replacement.submit.accessibilityPerformPress()); XCTAssertEqual(targets, ["two"])
    anchor.removeFromSuperview(); XCTAssertNil(owner.host.surface); XCTAssertFalse(WindowModalInteraction.blocksCommands(in: window))
    replacement.submit.activate?(); XCTAssertEqual(targets.count, 1); XCTAssertTrue(try writes(directory).isEmpty)
  }

  func testReadOnlyAndInvalidFormsCannotWriteOrStealBackgroundUndo() async throws {
    let (directory, state) = try await fixture(); state.openReview(); state.reviewBody = "Review"
    var valid = true, submissions = 0
    let (window, root, anchor, owner, form) = try host(state, writable: false, valid: { valid }, submit: { submissions += 1 })
    XCTAssertFalse(form.editor.isEditable); XCTAssertFalse(form.submit.accessibilityPerformPress())
    XCTAssertFalse(WindowModalInteraction.allowsTextEditing(in: window))
    let outside = NSTextView(frame: .init(x: 0, y: 0, width: 100, height: 50)); root.addSubview(outside); window.makeFirstResponder(outside)
    XCTAssertFalse(WindowModalInteraction.allowsTextEditing(in: window)); owner.host.containFocus(); XCTAssertTrue(window.firstResponder === form.cancel)
    valid = false; owner.host.update(anchor); form.submit.activate?()
    XCTAssertNil(owner.host.surface); XCTAssertEqual(submissions, 0); XCTAssertTrue(try writes(directory).isEmpty)
  }

  func testNarrowReviewWrapsRadiosAndResizeStaysInsideAvailableWindow() async throws {
    let (_, state) = try await fixture(); state.openReview()
    let (_, root, _, _, form) = try host(state, width: 240)
    XCTAssertEqual(form.dialogFrame.width, 200); XCTAssertGreaterThan(Set(form.decisions.map { $0.frame.minY }).count, 1)
    form.resizeEditor(10000); root.layoutSubtreeIfNeeded()
    XCTAssertLessThanOrEqual(form.dialogFrame.maxY, root.bounds.maxY); XCTAssertGreaterThanOrEqual(form.editorHeight, 96)
    XCTAssertTrue(form.submit.accessibilityPerformPress()); root.layoutSubtreeIfNeeded()
    XCTAssertFalse(form.errorScroll.isHidden); XCTAssertLessThanOrEqual(form.dialogFrame.maxY, root.bounds.maxY)
    form.resizeEditor(10); root.layoutSubtreeIfNeeded(); XCTAssertEqual(form.editorHeight, 96)
    try render(root, "review-narrow")
  }

  func testSwiftUIObservationMountsAndRemovesBothDialogsInSameWindow() async throws {
    let (_, state) = try await fixture()
    let window = TestWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let content = NSHostingView(rootView: Text("PR").frame(width: 900, height: 700).background {
      PullRequestDiscussionDialogPresenter(state: state, request: request, writable: true, valid: { true }, submitReview: {}, confirmReview: {}, deleteComment: { _ in }).frame(width: 0, height: 0)
    })
    window.contentView = content; defer { window.contentView = nil; window.close(); state.cancel() }
    state.openReview(); try await Task.sleep(for: .milliseconds(150)); content.layoutSubtreeIfNeeded()
    let review = try XCTUnwrap(content.subviews.compactMap { $0 as? PullRequestDiscussionDialogPresenter.Surface }.first)
    XCTAssertEqual(review.mode, .review); XCTAssertNil(window.attachedSheet)
    state.closeReview(); try await Task.sleep(for: .milliseconds(150)); XCTAssertNil(review.superview)
    state.deleteTarget = try XCTUnwrap(state.snapshot?.comment("one")); try await Task.sleep(for: .milliseconds(150))
    let deletion = try XCTUnwrap(content.subviews.compactMap { $0 as? PullRequestDiscussionDialogPresenter.Surface }.first)
    content.layoutSubtreeIfNeeded()
    XCTAssertEqual(deletion.dialogFrame.width, 520); state.deleteTarget = nil
    try await Task.sleep(for: .milliseconds(150)); XCTAssertNil(deletion.superview); XCTAssertFalse(WindowModalInteraction.blocksCommands(in: window))
  }
  func testEmptyApprovalIsSubmittedOnceWithoutCommentBody() async throws {
    let (directory, state) = try await fixture(); state.openReview(); state.reviewDecision = .approve
    let (_, _, _, _, form) = try host(state, submit: { self.start(state, state.reviewAction!, directory) })
    XCTAssertTrue(form.submit.accessibilityPerformPress()); await state.operation?.value
    XCTAssertFalse(state.showingReview); XCTAssertNil(state.uncertain)
    let calls = try writes(directory), input = try XCTUnwrap(calls.first?["input"] as? [String: Any])
    XCTAssertEqual(calls.count, 1); XCTAssertEqual(input["event"] as? String, "APPROVE"); XCTAssertNil(input["body"])
  }

  func testUncertainReviewRereadsResultWithoutResubmitting() async throws {
    let (directory, state) = try await fixture(["discussionFailAfterAction": true, "discussionFailureAfterAction": true])
    state.openReview(); state.reviewBody = "Review"
    let (_, _, anchor, owner, form) = try host(state, submit: { self.start(state, state.reviewAction!, directory) }, confirm: {
      XCTAssertTrue(state.confirm(request: self.request, at: directory, valid: { true }))
    })
    XCTAssertTrue(form.submit.accessibilityPerformPress()); await state.operation?.value; owner.configure(form)
    XCTAssertEqual(state.uncertainOwner, .review); XCTAssertFalse(form.editor.isEditable)
    XCTAssertEqual(form.submit.title, "重新读取操作结果"); XCTAssertTrue(form.submit.isEnabled)
    let path = directory.appendingPathComponent(".git/github-fixture.json")
    var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
    fields["discussionFailureAfterAction"] = false; try JSONSerialization.data(withJSONObject: fields).write(to: path)
    XCTAssertTrue(form.submit.accessibilityPerformPress()); await state.operation?.value; owner.host.update(anchor)
    XCTAssertNil(state.uncertain); XCTAssertNil(owner.host.surface); XCTAssertFalse(state.showingReview)
    XCTAssertEqual(try writes(directory).count, 1)
  }

  func testClosingReplacementRestoresOriginalLiveSourceAndPreservesOtherModal() async throws {
    let (_, state) = try await fixture(); state.deleteTarget = try XCTUnwrap(state.snapshot?.comment("one"))
    let source = NSTextView(frame: .init(x: 0, y: 0, width: 100, height: 50))
    let (window, root, anchor, owner, old) = try host(state, source: source)
    state.deleteTarget = try XCTUnwrap(state.snapshot?.comment("two")); owner.host.update(anchor)
    let replacement = try XCTUnwrap(owner.host.surface as? PullRequestDiscussionDialogPresenter.Surface)
    XCTAssertFalse(old.cancel.accessibilityPerformPress()); XCTAssertTrue(replacement.cancel.accessibilityPerformPress())
    try await Task.sleep(for: .milliseconds(30)); XCTAssertTrue(window.firstResponder === source)
    state.openReview(); owner.host.present(anchor)
    let other = Scope(root: NSView(frame: root.bounds)); root.addSubview(other.modalRoot)
    WindowModalInteraction.install(other, in: window); owner.stop()
    XCTAssertTrue(WindowModalInteraction.blocksCommands(in: window)); XCTAssertFalse(WindowModalInteraction.allows(root))
    XCTAssertTrue(WindowModalInteraction.allows(other.modalRoot))
    WindowModalInteraction.remove(other, from: window); other.modalRoot.removeFromSuperview()
  }
  private final class Scope: WindowModalScope {
    let modalRoot: NSView
    var modalScopeActive: Bool { true }
    var blocksWorkspaceCommands: Bool { true }
    init(root: NSView) { modalRoot = root }
  }

  func testOutsideClickEscapeAndCommandWCancelButRightClickDoesNot() async throws {
    let (directory, state) = try await fixture(); state.openReview(); state.reviewBody = "Draft"
    let (window, _, anchor, owner, form) = try host(state)
    func mouse(_ point: NSPoint, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
      try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: flags,
        timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    let outside = try mouse(.init(x: 1, y: 1))
    form.rightMouseDown(with: outside); form.mouseDown(with: try mouse(.init(x: 1, y: 1), .control))
    form.mouseDown(with: try mouse(form.convert(.init(x: form.dialogFrame.midX, y: form.dialogFrame.midY), to: nil)))
    XCTAssertTrue(state.showingReview); form.mouseDown(with: outside)
    XCTAssertFalse(state.showingReview); XCTAssertNil(owner.host.surface); XCTAssertEqual(state.reviewBody, "Draft")
    state.openReview(); owner.host.present(anchor); XCTAssertTrue(owner.host.handle(try key(53, window)))
    XCTAssertFalse(state.showingReview)
    state.openReview(); owner.host.present(anchor); XCTAssertTrue(owner.host.handle(try key(13, window, flags: .command)))
    XCTAssertFalse(state.showingReview); XCTAssertEqual(state.reviewBody, "Draft"); XCTAssertTrue(try writes(directory).isEmpty)
  }

}
