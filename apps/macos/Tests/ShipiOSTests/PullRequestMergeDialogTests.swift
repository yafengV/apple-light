import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class PullRequestMergeDialogTests: XCTestCase {
  private let request = GitHubPullRequest(number: 42, url: "https://github.com/sample/project/pull/42",
    title: "Feature", isDraft: false, headRefName: "feature", baseRefName: "main", isCrossRepository: false)
  private final class TestWindow: NSWindow { override var isKeyWindow: Bool { true } }
  private func fixture(_ changes: [String: Any] = [:]) async throws -> (URL, GitHubPRDetailState) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pr-dialog-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    _ = try await GitReviewService.checked(["init", "-q", "-b", "feature"], at: root)
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/github_cli.py")
    let executable = root.appendingPathComponent(".git/gh-fixture")
    try FileManager.default.copyItem(at: source, to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let item = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    var fields: [String: Any] = ["head": String(repeating: "a", count: 40), "viewer": "owner", "author": "owner",
      "mergeable": "MERGEABLE", "pullRequests": [item]]
    changes.forEach { fields[$0.key] = $0.value }
    try JSONSerialization.data(withJSONObject: fields).write(to: root.appendingPathComponent(".git/github-fixture.json"))
    let state = GitHubPRDetailState(service: .init(executable: executable), coordinator: .init())
    await state.refresh(request, at: root, preferred: .squash, valid: { true }, updated: { _ in })
    return (root, state)
  }
  private func host(_ state: GitHubPRDetailState, width: CGFloat = 900, writable: Bool = true,
    valid: @escaping () -> Bool = { true }, confirm: @escaping () -> Void = {}) throws
    -> (NSWindow, NSView, PullRequestMergeDialogPresenter.Anchor, PullRequestMergeDialogPresenter.Coordinator, PullRequestMergeDialogPresenter.Surface) {
    let window = TestWindow(contentRect: .init(x: 0, y: 0, width: width, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
    let root = NSView(frame: .init(x: 0, y: 0, width: width, height: 600)); root.wantsLayer = true
    root.layer?.backgroundColor = NSColor.white.cgColor; window.contentView = root
    let presenter = PullRequestMergeDialogPresenter(state: state, request: request, writable: writable, valid: valid, confirm: confirm)
    let owner = presenter.makeCoordinator(), anchor = PullRequestMergeDialogPresenter.Anchor(frame: .init(x: 650, y: 100, width: 1, height: 1))
    anchor.owner = owner; root.addSubview(anchor)
    state.showingMergeConfirmation = true; owner.present(in: anchor)
    let surface = try XCTUnwrap(owner.surface); root.layoutSubtreeIfNeeded()
    addTeardownBlock { @MainActor in owner.stop(); window.contentView = nil; window.close(); state.cancel() }
    return (window, root, anchor, owner, surface)
  }
  private func key(_ code: UInt16, _ window: NSWindow, flags: NSEvent.ModifierFlags = [], repeatKey: Bool = false) throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: code == 13 ? "w" : "",
      charactersIgnoringModifiers: code == 13 ? "w" : "", isARepeat: repeatKey, keyCode: code))
  }
  private func writes(_ root: URL) throws -> [[String]] {
    let path = root.appendingPathComponent(".git/github-requests.jsonl")
    guard FileManager.default.fileExists(atPath: path.path) else { return [] }
    return try String(contentsOf: path).split(separator: "\n").compactMap {
      let item = try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any], args = item?["args"] as? [String]
      return args?.prefix(2) == ["pr", "merge"] ? args : nil
    }
  }
  private func render(_ root: NSView, _ name: String) throws {
    guard let path = ProcessInfo.processInfo.environment["SHIPIOS_PR_DIALOG_RENDER_DIR"] else { return }
    root.layoutSubtreeIfNeeded()
    let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
    root.cacheDisplay(in: root.bounds, to: bitmap)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      .write(to: URL(fileURLWithPath: path).appendingPathComponent(name + ".png"))
  }

  func testCurrentReferenceFormContractAcrossFiveActualComponentCases() throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures/pr_merge_confirmation_reference.json")
    let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    XCTAssertEqual(fixture["version"] as? String, "26.930.21537")
    XCTAssertEqual(fixture["sha256"] as? String, "e72f55755ce74c0dafef2af133be03b96b0ae5ccc1d31bcf913d8696221238db")
    XCTAssertEqual(fixture["defaultWidth"] as? Int, 520); XCTAssertEqual(fixture["bodyPadding"] as? Int, 20)
    let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
    XCTAssertEqual(cases.count, 5)
    for item in cases {
      let pending = try XCTUnwrap(item["pending"] as? Bool), name = try XCTUnwrap(item["name"] as? String)
      XCTAssertEqual(item["showDialogClose"] as? Bool, false)
      XCTAssertEqual(item["cancelDisabled"] as? Bool, pending); XCTAssertEqual(item["confirmLoading"] as? Bool, pending)
      XCTAssertEqual(item["prevented"] as? Bool, true)
      let calls = try XCTUnwrap(item["calls"] as? [String: Any])
      XCTAssertEqual(calls["merge"] as? Int, pending ? 0 : 1)
      XCTAssertEqual(calls["closed"] as? [Bool], pending ? [] : [false])
      XCTAssertEqual(item["methodOptions"] as? [String], name == "single" ? [] : ["squash", "merge"])
      XCTAssertEqual(item["bodySections"] as? Int, name == "single" ? 2 : name == "error" ? 4 : 3)
    }
  }

  func testFullWindowSurfaceFromNarrowPaneContainsOnlyReferenceFormFields() async throws {
    let (directory, state) = try await fixture(), (window, root, anchor, _, surface) = try host(state)
    XCTAssertTrue(surface.superview === root); XCTAssertFalse(surface.isDescendant(of: anchor))
    XCTAssertEqual(surface.bounds.size, root.bounds.size); XCTAssertNil(window.attachedSheet); XCTAssertFalse(window.isVisible)
    XCTAssertEqual(surface.dialogFrame.width, 520); XCTAssertEqual(surface.dialogFrame.midX, root.bounds.midX)
    XCTAssertEqual(surface.dialogFrame.midY, root.bounds.midY)
    XCTAssertEqual(surface.accessibilitySubrole(), .dialog); XCTAssertTrue(surface.isAccessibilityModal())
    XCTAssertEqual(surface.accessibilityFrame().size, surface.dialogFrame.size)
    XCTAssertEqual(surface.controls.map(\.title), ["压缩", "合并提交", "取消", "压缩并合并"])
    XCTAssertEqual(surface.subviews.compactMap { ($0 as? NSTextField)?.stringValue },
      ["合并 Pull Request", "GitHub 只会在当前显示的头提交仍然匹配时合并。"])
    XCTAssertTrue(surface.errorScroll.isHidden); XCTAssertTrue(try writes(directory).isEmpty)
    try render(root, "merge-two-methods")
  }

  func testTabBacktabCyclesAllButtonsEnterSelectsSpaceCancelsAndDoesNotMerge() async throws {
    let (directory, state) = try await fixture(), (window, _, _, owner, surface) = try host(state, confirm: { XCTFail() })
    XCTAssertTrue(window.firstResponder === surface.squash)
    XCTAssertTrue(owner.handle(try key(48, window))); XCTAssertTrue(window.firstResponder === surface.merge)
    XCTAssertTrue(owner.handle(try key(36, window))); XCTAssertEqual(state.selectedMethod, .merge)
    XCTAssertTrue(surface.merge.selected); XCTAssertEqual(surface.submit.title, "创建合并提交")
    XCTAssertTrue(owner.handle(try key(48, window))); XCTAssertTrue(window.firstResponder === surface.cancel)
    XCTAssertTrue(owner.handle(try key(48, window, flags: .shift))); XCTAssertTrue(window.firstResponder === surface.merge)
    window.makeFirstResponder(surface.squash)
    XCTAssertTrue(owner.handle(try key(48, window, flags: .shift))); XCTAssertTrue(window.firstResponder === surface.submit)
    XCTAssertTrue(owner.handle(try key(48, window))); XCTAssertTrue(window.firstResponder === surface.squash)
    window.makeFirstResponder(surface.cancel); XCTAssertTrue(owner.handle(try key(49, window)))
    XCTAssertFalse(state.showingMergeConfirmation); XCTAssertNil(owner.surface); XCTAssertTrue(try writes(directory).isEmpty)
  }

  func testSingleMethodOmitsSelectorAndCancelGetsInitialFocus() async throws {
    let (_, state) = try await fixture(["allowMerge": false]), (window, root, _, owner, surface) = try host(state)
    XCTAssertTrue(surface.squash.isHidden); XCTAssertTrue(surface.merge.isHidden)
    XCTAssertEqual(surface.controls.map(\.title), ["取消", "压缩并合并"])
    XCTAssertTrue(window.firstResponder === surface.cancel)
    XCTAssertTrue(owner.handle(try key(48, window))); XCTAssertTrue(window.firstResponder === surface.submit)
    XCTAssertTrue(owner.handle(try key(48, window))); XCTAssertTrue(window.firstResponder === surface.cancel)
    try render(root, "merge-single-method")
  }

  func testRealSubmissionIsSingleUsesCapturedMethodAndBusyBlocksDismissal() async throws {
    let (directory, state) = try await fixture(["mutationDelay": 0.2])
    var count = 0
    let (window, _, _, owner, surface) = try host(state, confirm: {
      count += 1
      state.start(.merge(state.selectedMethod), request: self.request, at: directory, valid: { true }, writable: { true }, updated: { _ in })
    })
    window.makeFirstResponder(surface.submit)
    XCTAssertTrue(owner.handle(try key(36, window))); XCTAssertEqual(count, 1)
    owner.submit(); owner.dismiss(); XCTAssertFalse(surface.submit.accessibilityPerformPress())
    XCTAssertFalse(surface.cancel.accessibilityPerformPress()); XCTAssertEqual(count, 1); XCTAssertTrue(state.showingMergeConfirmation)
    XCTAssertTrue(owner.handle(try key(53, window))); XCTAssertTrue(state.showingMergeConfirmation)
    XCTAssertTrue(owner.handle(try key(13, window, flags: .command))); XCTAssertTrue(state.showingMergeConfirmation)
    XCTAssertTrue(surface.merge.accessibilityPerformPress()); XCTAssertEqual(state.selectedMethod, .merge)
    await state.operation?.value
    XCTAssertFalse(state.showingMergeConfirmation); XCTAssertNil(state.error)
    let commands = try writes(directory); XCTAssertEqual(commands.count, 1); XCTAssertTrue(commands[0].contains("--squash"))
  }

  func testBusyFormRetainsMethodsButDisablesFooterThenFailureShowsAlertAndRetry() async throws {
    let (directory, state) = try await fixture(["mutationDelay": 0.15, "mergeRestriction": true])
    state.selectedMethod = .merge
    let (window, root, anchor, owner, surface) = try host(state, confirm: {
      state.start(.merge(state.selectedMethod), request: self.request, at: directory, valid: { true }, writable: { true }, updated: { _ in })
    })
    owner.submit()
    owner.update(anchor, showing: true, busy: state.busy(for: request), methods: state.snapshot?.allowedMethods,
      selected: state.selectedMethod, error: state.error, reason: state.mergeDisabledReason(for: request, writable: true))
    XCTAssertFalse(surface.cancel.isEnabled); XCTAssertFalse(surface.submit.isEnabled); XCTAssertTrue(surface.merge.isEnabled)
    root.layoutSubtreeIfNeeded()
    XCTAssertTrue(surface.submit.loading); XCTAssertTrue(surface.submit.frame.contains(surface.progress.frame))
    await state.operation?.value
    XCTAssertTrue(state.showingMergeConfirmation); XCTAssertNotNil(state.error)
    owner.update(anchor, showing: true, busy: false, methods: state.snapshot?.allowedMethods,
      selected: state.selectedMethod, error: state.error, reason: state.mergeDisabledReason(for: request, writable: true))
    XCTAssertFalse(surface.errorScroll.isHidden); XCTAssertEqual(surface.error.stringValue, state.error)
    XCTAssertTrue(surface.submit.isEnabled); XCTAssertTrue(surface.cancel.isEnabled)
    XCTAssertEqual(surface.submit.title, "压缩并合并"); try render(root, "merge-retry-error")
    window.makeFirstResponder(surface.submit); XCTAssertTrue(owner.handle(try key(36, window)))
    await state.operation?.value; XCTAssertFalse(state.showingMergeConfirmation); XCTAssertNil(state.error)
  }

  func testReadonlyAndStaleOwnerRejectOldCallbackWithoutAnyWrite() async throws {
    let (directory, state) = try await fixture(); var valid = true, invoked = 0
    let (_, _, anchor, owner, surface) = try host(state, valid: { valid }, confirm: { invoked += 1 })
    owner.parent = PullRequestMergeDialogPresenter(state: state, request: request, writable: false, valid: { valid }, confirm: { invoked += 1 })
    owner.submit(); XCTAssertFalse(surface.submit.accessibilityPerformPress()); XCTAssertEqual(invoked, 0)
    valid = false; owner.dismiss(); XCTAssertTrue(state.showingMergeConfirmation)
    owner.update(anchor, showing: true, busy: false, methods: state.snapshot?.allowedMethods, selected: state.selectedMethod, error: nil, reason: nil)
    XCTAssertNil(owner.surface); XCTAssertFalse(surface.submit.accessibilityPerformPress()); XCTAssertFalse(surface.squash.accessibilityPerformPress())
    XCTAssertTrue(try writes(directory).isEmpty)
  }

  func testModalContainsPointerAndFocusBlocksOnlyOwningWindowCommands() async throws {
    let (_, state) = try await fixture(), (window, root, _, owner, surface) = try host(state)
    let background = NSButton(title: "background", target: nil, action: nil); background.frame = .init(x: 0, y: 0, width: 100, height: 100)
    root.addSubview(background, positioned: .below, relativeTo: surface)
    XCTAssertFalse(WindowModalInteraction.allows(background)); XCTAssertTrue(WindowModalInteraction.blocksCommands(in: window))
    let other = NSWindow(); other.isReleasedWhenClosed = false; defer { other.close() }; XCTAssertFalse(WindowModalInteraction.blocksCommands(in: other))
    XCTAssertTrue(surface.hitTest(.init(x: 5, y: 5)) === surface)
    window.makeFirstResponder(background); owner.containFocus(); XCTAssertTrue(window.firstResponder === surface.squash)
    owner.dismiss(); XCTAssertTrue(WindowModalInteraction.allows(background)); XCTAssertFalse(WindowModalInteraction.blocksCommands(in: window))
  }

  func testEscapeReturnsLiveTriggerAndInvalidatedButtonsCannotAct() async throws {
    let (_, state) = try await fixture()
    let (window, root, anchor, owner, old) = try host(state)
    owner.dismiss(); try await Task.sleep(for: .milliseconds(20))
    let trigger = NSButton(title: "trigger", target: nil, action: nil); root.addSubview(trigger); window.makeFirstResponder(trigger)
    state.showingMergeConfirmation = true; owner.present(in: anchor)
    let surface = try XCTUnwrap(owner.surface)
    XCTAssertFalse(old.submit.accessibilityPerformPress()); XCTAssertFalse(old.cancel.accessibilityPerformPress())
    XCTAssertTrue(owner.handle(try key(53, window)))
    // A subsequent SwiftUI update must not cancel the scheduled return focus.
    owner.update(anchor, showing: false, busy: false, methods: nil, selected: .squash, error: nil, reason: nil)
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertTrue(window.firstResponder === trigger); XCTAssertNil(surface.superview)
  }

  func testResizeFillsWindowAndKeepsDialogCenteredWithUsableButtons() async throws {
    let (_, state) = try await fixture(), (_, root, _, _, surface) = try host(state, width: 360)
    XCTAssertEqual(surface.dialogFrame.width, 320); XCTAssertEqual(surface.dialogFrame.midX, 180)
    XCTAssertTrue(surface.dialogFrame.contains(surface.cancel.frame)); XCTAssertTrue(surface.dialogFrame.contains(surface.submit.frame))
    try render(root, "merge-narrow")
    root.setFrameSize(.init(width: 1200, height: 800)); root.layoutSubtreeIfNeeded()
    XCTAssertEqual(surface.bounds.size, root.bounds.size); XCTAssertEqual(surface.dialogFrame.width, 520)
    XCTAssertEqual(surface.dialogFrame.midX, 600); XCTAssertEqual(surface.dialogFrame.midY, 400)
  }

  func testDetachingAnchorCleansWindowScopeAndNativeCallbacks() async throws {
    let (_, state) = try await fixture(), (window, _, anchor, owner, surface) = try host(state)
    anchor.removeFromSuperview()
    XCTAssertNil(owner.surface); XCTAssertNil(surface.superview)
    XCTAssertFalse(WindowModalInteraction.blocksCommands(in: window))
    XCTAssertFalse(surface.submit.accessibilityPerformPress())
    owner.present(in: anchor); XCTAssertNil(owner.surface)
  }

  func testReplacementModalKeepsItsScopeAndFocusWhenOldPresenterStops() async throws {
    let (_, state) = try await fixture(), (window, root, _, owner, surface) = try host(state)
    let other = PullRequestMergeDialogPresenter.Surface(frame: root.bounds)
    let replacement = Scope(root: other); root.addSubview(other)
    WindowModalInteraction.install(replacement, in: window)
    window.makeFirstResponder(other.cancel)
    XCTAssertFalse(surface.cancel.accessibilityPerformPress())
    owner.dismiss(); XCTAssertTrue(state.showingMergeConfirmation)
    owner.stop()
    XCTAssertTrue(WindowModalInteraction.blocksCommands(in: window))
    XCTAssertFalse(WindowModalInteraction.allows(root))
    WindowModalInteraction.remove(replacement, from: window)
    XCTAssertFalse(WindowModalInteraction.blocksCommands(in: window))
  }
  private final class Scope: WindowModalScope {
    let modalRoot: NSView
    var modalScopeActive: Bool { true }
    var blocksWorkspaceCommands: Bool { true }
    init(root: NSView) { modalRoot = root }
  }

  func testSwiftUIObservationPresentsAndRemovesOverlayWithoutSheet() async throws {
    let (_, state) = try await fixture()
    let window = TestWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let content = NSHostingView(rootView: Text("PR pane").background {
      PullRequestMergeDialogPresenter(state: state, request: request, writable: true, valid: { true }, confirm: {})
        .frame(width: 0, height: 0)
    })
    window.contentView = content; defer { window.contentView = nil; window.close(); state.cancel() }
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertTrue(content.subviews.compactMap { $0 as? PullRequestMergeDialogPresenter.Surface }.isEmpty)
    state.openConfirmation(for: request, writable: true)
    try await Task.sleep(for: .milliseconds(150)); content.layoutSubtreeIfNeeded()
    let surface = try XCTUnwrap(content.subviews.compactMap { $0 as? PullRequestMergeDialogPresenter.Surface }.first)
    XCTAssertEqual(surface.bounds.size, content.bounds.size); XCTAssertNil(window.attachedSheet)
    state.showingMergeConfirmation = false
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertNil(surface.superview); XCTAssertFalse(WindowModalInteraction.blocksCommands(in: window))
  }
}
