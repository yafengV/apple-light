import AppKit
import XCTest
@testable import ShipiOS

final class GitPullRequestPresentationTests: XCTestCase {
  func testURLPreservesLiteralQueryAndBranchCharacters() throws {
    let repository = try GitHubRepository.parse("git@github.com:sample/project.git")
    let title = "Symbols + & # = ? 中文"
    let body = "## Summary\n\n`$(literal)` + and & # / ? = % 😀"
    let url = try GitHubPRService.compareURL(repository: repository, base: "release/版本", head: "feature/#topic",
      title: title, body: body)
    XCTAssertEqual(url.scheme, "https")
    XCTAssertEqual(url.host, "github.com")
    XCTAssertNil(url.fragment)
    XCTAssertTrue(url.absoluteString.contains("release%2F%E7%89%88%E6%9C%AC...feature%2F%23topic"))
    // Simulate web form decoding, where an unescaped plus becomes a space.
    let components = try XCTUnwrap(URLComponents(string: url.absoluteString.replacingOccurrences(of: "+", with: " ")))
    XCTAssertEqual(components.queryItems?.first { $0.name == "title" }?.value, title)
    XCTAssertEqual(components.queryItems?.first { $0.name == "body" }?.value, body)
    XCTAssertEqual(components.queryItems?.first { $0.name == "expand" }?.value, "1")
  }

  func testBrowserURLLimitAndInvalidFields() throws {
    let repository = try GitHubRepository.parse("https://github.com/sample/project")
    for (base, head, title, body) in [
      ("main", "feature", "", "body"), ("main", "feature", "two\nlines", "body"),
      ("main", "main", "Title", "body"), ("", "feature", "Title", "body"),
      ("main", "", "Title", "body"), ("main", "feature", "Title", String(repeating: "界", count: 1000))
    ] {
      XCTAssertThrowsError(try GitHubPRService.compareURL(repository: repository, base: base, head: head,
        title: title, body: body))
    }
    let empty = try GitHubPRService.compareURL(repository: repository, base: "main", head: "feature",
      title: "Title", body: "")
    let remaining = 8191 - empty.absoluteString.utf8.count
    let maximum = try GitHubPRService.compareURL(repository: repository, base: "main", head: "feature",
      title: "Title", body: String(repeating: "a", count: remaining))
    XCTAssertEqual(maximum.absoluteString.utf8.count, 8191)
    XCTAssertThrowsError(try GitHubPRService.compareURL(repository: repository, base: "main", head: "feature",
      title: "Title", body: String(repeating: "a", count: remaining + 1)))
  }

  private func key(_ code: UInt16, flags: NSEvent.ModifierFlags = [], text: String = "",
    multiline: Bool = false, marked: Bool = false) throws -> PullRequestKeyboardBridge.Key? {
    let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
      timestamp: 0, windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
      isARepeat: false, keyCode: code))
    return PullRequestKeyboardBridge.key(for: event, markedText: marked, multilineText: multiline)
  }

  func testDescriptionEnterArrowsTabAndEditingRemainNative() throws {
    for code: UInt16 in [36, 76, 125, 126, 123, 124, 48, 49] {
      XCTAssertNil(try key(code, multiline: true))
    }
    XCTAssertNil(try key(48, flags: .shift, multiline: true))
    XCTAssertNil(try key(8, flags: .command, text: "c", multiline: true))
    XCTAssertNil(try key(6, flags: .command, text: "z", multiline: true))
    XCTAssertNil(try key(36, flags: .shift, multiline: true))
    XCTAssertEqual(try key(36, flags: .command, multiline: true), .activate)
    XCTAssertEqual(try key(76, flags: [.command, .numericPad], multiline: true), .activate)
  }

  func testTitleAndActionCommandsLoopWhileIMECompositionIsProtected() throws {
    XCTAssertEqual(try key(36), .activate)
    XCTAssertEqual(try key(125), .move(1))
    XCTAssertEqual(try key(126), .move(-1))
    XCTAssertEqual(try key(53, multiline: true), .cancel)
    XCTAssertEqual(try key(13, flags: .command, text: "w", multiline: true), .cancel)
    for code: UInt16 in [36, 76, 125, 126, 53] {
      XCTAssertNil(try key(code, marked: true))
      XCTAssertNil(try key(code, flags: .command, multiline: true, marked: true))
    }
    XCTAssertNil(try key(48))
    XCTAssertNil(try key(48, flags: .shift))
    XCTAssertNil(try key(123))
    XCTAssertNil(try key(125, flags: .option))
  }

  func testBranchReturnKeepsEditingWhileCommandReturnActivatesAndIMEIsProtected() throws {
    for code: UInt16 in [36, 76] {
      let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
        isARepeat: false, keyCode: code))
      XCTAssertNil(PullRequestKeyboardBridge.key(for: event, markedText: false,
        multilineText: false, branchField: true))
      let command = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
        timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
        isARepeat: false, keyCode: code))
      XCTAssertEqual(PullRequestKeyboardBridge.key(for: command, markedText: false,
        multilineText: false, branchField: true), .activate)
      XCTAssertNil(PullRequestKeyboardBridge.key(for: command, markedText: true,
        multilineText: false, branchField: true))
    }
  }

  func testVisibleActionsAndPreferenceAndExistingSelection() {
    XCTAssertEqual(GitPullRequestAction.creationActions, [.createDraft, .create, .openBrowser])
    XCTAssertEqual(GitPullRequestAction.initial(existing: false, defaultToDraft: true), .createDraft)
    XCTAssertEqual(GitPullRequestAction.initial(existing: false, defaultToDraft: false), .create)
    XCTAssertEqual(GitPullRequestAction.initial(existing: true, defaultToDraft: true), .openExisting)
    XCTAssertEqual(GitPullRequestAction.create.moved(by: 1, existing: false), .openBrowser)
    XCTAssertEqual(GitPullRequestAction.openBrowser.moved(by: 1, existing: false), .createDraft)
    XCTAssertEqual(GitPullRequestAction.createDraft.moved(by: -1, existing: false), .openBrowser)
    XCTAssertEqual(GitPullRequestAction.openExisting.moved(by: 1, existing: true), .openExisting)
  }

  @MainActor func testBridgeDoesNotRetainAnchorOrCoordinatorAfterRemoval() {
    weak var weakView: NSView?
    weak var weakCoordinator: PullRequestKeyboardBridge.Coordinator?
    do {
      let view = NSView()
      let coordinator = PullRequestKeyboardBridge.Coordinator(action: { _ in XCTFail("No event was sent") })
      weakView = view; weakCoordinator = coordinator
      coordinator.install(view)
      coordinator.stop()
      coordinator.stop()
    }
    XCTAssertNil(weakView)
    XCTAssertNil(weakCoordinator)
  }

  @MainActor func testDismissResetsOnlyFormAndKeepsBaseAndErrorMetadata() {
    let workspace = DeveloperWorkspace()
    workspace.root = URL(fileURLWithPath: "/tmp/pr-modal-presentation")
    let draft = workspace.pullRequestDraft
    draft.title = "Dismissed title"; draft.body = "Dismissed body"
    draft.base = "release"; draft.includeLocalChanges = false
    draft.reportError("Existing failure")
    let scope = GitPullRequestModalScope(workspace: workspace)
    scope.disappear()
    XCTAssertEqual(draft.title, "")
    XCTAssertEqual(draft.body, "")
    XCTAssertTrue(draft.includeLocalChanges)
    XCTAssertEqual(draft.base, "release")
    XCTAssertEqual(draft.error, "Existing failure")
    XCTAssertFalse(draft.loading)
  }

  @MainActor func testHandedOffAndPendingActionDisappearanceKeepsAcceptedInput() throws {
    let workspace = DeveloperWorkspace()
    let draft = workspace.pullRequestDraft
    draft.title = "Accepted title"; draft.body = "Accepted body"; draft.includeLocalChanges = false
    let scope = GitPullRequestModalScope(workspace: workspace)
    scope.handOffAction()
    scope.disappear()
    XCTAssertEqual(draft.title, "Accepted title")
    XCTAssertEqual(draft.body, "Accepted body")
    XCTAssertFalse(draft.includeLocalChanges)
    let reservation = try XCTUnwrap(draft.reserveModalAction())
    scope.disappear()
    XCTAssertTrue(draft.modalActionPending)
    XCTAssertEqual(draft.title, "Accepted title")
    XCTAssertFalse(draft.includeLocalChanges)
    scope.settle(.openBrowser, reservation: reservation)
    XCTAssertFalse(draft.modalActionPending)
    XCTAssertEqual(draft.body, "Accepted body")
    XCTAssertFalse(draft.includeLocalChanges)
  }

  @MainActor func testOldPresentationCannotResetReplacementDraftOrChangedRepository() {
    let workspace = DeveloperWorkspace()
    workspace.root = URL(fileURLWithPath: "/tmp/old-pr-repository")
    let original = workspace.pullRequestDraft
    original.title = "Original title"
    let scope = GitPullRequestModalScope(workspace: workspace)
    let replacement = GitHubPRDraft()
    replacement.title = "Replacement title"; replacement.body = "Replacement body"
    replacement.includeLocalChanges = false
    workspace.pullRequestDraft = replacement
    scope.disappear()
    XCTAssertFalse(scope.isCurrent)
    XCTAssertEqual(replacement.title, "Replacement title")
    XCTAssertEqual(replacement.body, "Replacement body")
    XCTAssertFalse(replacement.includeLocalChanges)
    XCTAssertEqual(original.title, "Original title")
    let replacementScope = GitPullRequestModalScope(workspace: workspace)
    workspace.root = URL(fileURLWithPath: "/tmp/new-pr-repository")
    replacementScope.disappear()
    XCTAssertFalse(replacementScope.isCurrent)
    XCTAssertEqual(replacement.title, "Replacement title")
  }

  @MainActor func testLateSettlementCannotReleaseOrResetNewReservation() throws {
    let draft = GitHubPRDraft()
    let old = try XCTUnwrap(draft.reserveModalAction())
    XCTAssertNil(draft.reserveModalAction())
    draft.finishModalAction(old, reset: true)
    draft.title = "New input"; draft.body = "New body"; draft.includeLocalChanges = false
    let next = try XCTUnwrap(draft.reserveModalAction())
    draft.finishModalAction(old, reset: true)
    XCTAssertEqual(draft.modalActionToken, next)
    XCTAssertEqual(draft.title, "New input")
    XCTAssertEqual(draft.body, "New body")
    XCTAssertFalse(draft.includeLocalChanges)
    draft.finishModalAction(next, reset: true)
    XCTAssertFalse(draft.modalActionPending)
    XCTAssertEqual(draft.title, "")
    XCTAssertTrue(draft.includeLocalChanges)
  }


  @MainActor func testLateHandedOffDisappearanceDoesNotResetReopenedFormInSameWorkspace() {
    let workspace = DeveloperWorkspace()
    let old = GitPullRequestModalScope(workspace: workspace)
    XCTAssertTrue(old.canStartAction)
    old.handOffAction()
    XCTAssertFalse(old.canStartAction)
    let reopened = GitPullRequestModalScope(workspace: workspace)
    XCTAssertTrue(reopened.canStartAction)
    let draft = workspace.pullRequestDraft
    draft.title = "Reopened browser title"; draft.body = "Reopened browser body"
    draft.includeLocalChanges = false
    old.disappear()
    XCTAssertEqual(draft.title, "Reopened browser title")
    XCTAssertEqual(draft.body, "Reopened browser body")
    XCTAssertFalse(draft.includeLocalChanges)
    reopened.disappear()
    XCTAssertEqual(draft.title, "")
    XCTAssertEqual(draft.body, "")
    XCTAssertTrue(draft.includeLocalChanges)
  }

}
