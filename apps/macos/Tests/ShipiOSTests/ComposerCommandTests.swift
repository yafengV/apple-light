import XCTest

@testable import ShipiOS

final class ComposerCommandTests: XCTestCase {
  private let all = Set(ComposerCommand.allCases)

  func testFilterAndNonCommandDrafts() {
    var selection = ComposerCommandSelection()
    selection.update(draft: "/MO", enabled: all)
    XCTAssertEqual(selection.matches, [.model])
    XCTAssertEqual(selection.handle(.accept), .accept(.model))
    for text in ["", "hello /model", "/model ", "/model\n", "/unknown"] {
      selection.update(draft: text, enabled: all)
      XCTAssertFalse(selection.isVisible)
      XCTAssertEqual(selection.handle(.accept), .ignored)
    }
  }

  @MainActor func testPlanCommandEntersOneShotModeAndTaskChangeClearsIt() {
    let store = WorkspaceStore()
    store.draft = "/plan"
    var selection = ComposerCommandSelection()
    selection.update(draft: store.draft, enabled: store.enabledComposerCommands)
    XCTAssertEqual(selection.matches, [.plan])
    store.selectComposerCommand(.plan)
    XCTAssertEqual(store.action, .chat)
    XCTAssertEqual(store.chatMode, .plan)
    XCTAssertEqual(store.draft, "")

    store.newTask()
    XCTAssertEqual(store.chatMode, .standard)

    store.draft = "/plan  inspect this flow"
    XCTAssertFalse(store.handleComposerCommand())
    XCTAssertEqual(store.chatMode, .plan)
    XCTAssertEqual(store.draft, "inspect this flow")
  }

  func testQueuedMessageWithoutModeMigratesToStandard() throws {
    let id = UUID()
    let data = Data(
      #"{"id":"\#(id.uuidString)","taskID":"task","text":"legacy","images":[],"files":[]}"#.utf8)
    let message = try JSONDecoder().decode(QueuedMessage.self, from: data)
    XCTAssertEqual(message.mode, .standard)
  }

  @MainActor func testContinueFromPlanPrefillsStandardDraftWithoutOverwritingWork() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    let now = Date().timeIntervalSince1970 * 1000
    let run = AgentRun(
      id: "plan", kind: "chat", project: "", status: "succeeded", createdAt: now,
      updatedAt: now,
      request: .object(["model": .string("fixture"), "mode": .string("plan")]),
      result: .object(["response": .string("1. Inspect")]))
    store.library.attach(run, to: nil, note: "plan this")
    store.library.chatRuns = [run]
    store.runs = [run]
    store.selection = run.id
    store.continueFromPlan(run)
    XCTAssertEqual(store.chatMode, .standard)
    XCTAssertEqual(store.draft, "按照上面的计划开始实现。完成后运行相关验证并报告结果。")

    store.draft = "keep this"
    store.continueFromPlan(run)
    XCTAssertEqual(store.draft, "keep this")
    XCTAssertNotNil(store.error)
  }

  func testArrowSelectionSkipsDisabledCommandsAndStopsAtBounds() {
    var selection = ComposerCommandSelection()
    selection.update(draft: "/", enabled: [.chat, .new])
    XCTAssertEqual(selection.selected, .chat)
    _ = selection.handle(.previous)
    XCTAssertEqual(selection.selected, .chat)
    _ = selection.handle(.next)
    XCTAssertEqual(selection.handle(.accept), .accept(.new))
    _ = selection.handle(.next)
    XCTAssertEqual(selection.selected, .new)
    _ = selection.handle(.previous)
    XCTAssertEqual(selection.selected, .chat)
  }

  func testDismissStaysDismissedUntilTextChanges() {
    var selection = ComposerCommandSelection()
    selection.update(draft: "/", enabled: all)
    XCTAssertEqual(selection.handle(.dismiss), .handled)
    XCTAssertEqual(selection.draft, "/")
    selection.update(draft: "/", enabled: [.model])
    XCTAssertFalse(selection.isVisible)
    XCTAssertEqual(selection.handle(.accept), .ignored)
    selection.update(draft: "/mo", enabled: all)
    XCTAssertTrue(selection.isVisible)
    XCTAssertEqual(selection.selected, .model)
  }

  func testInputMethodCompositionDoesNotMoveAcceptOrDismiss() {
    var selection = ComposerCommandSelection()
    selection.update(draft: "/", enabled: all)
    for key in [ComposerCommandSelection.Key.previous, .next, .accept, .dismiss] {
      XCTAssertEqual(selection.handle(key, isComposing: true), .ignored)
      XCTAssertEqual(selection.selected, .chat)
      XCTAssertTrue(selection.isVisible)
    }
  }

  func testUnavailableSelectionIsClearedAndCannotSend() {
    var selection = ComposerCommandSelection()
    selection.update(draft: "/fork", enabled: all)
    selection.update(draft: "/fork", enabled: [])
    XCTAssertNil(selection.selected)
    XCTAssertTrue(selection.isVisible)
    XCTAssertEqual(selection.handle(.accept), .handled)
    selection.highlight(.fork)
    XCTAssertNil(selection.selected)
  }

  @MainActor func testLocalActionCompletionDoesNotExecuteOrDiscardDraft() {
    let store = WorkspaceStore()
    store.project = URL(fileURLWithPath: "/project")
    store.selectComposerCommand(.build)
    XCTAssertEqual(store.action, .build)
    XCTAssertEqual(store.draft, "/build ")
    XCTAssertTrue(store.runs.isEmpty)
    XCTAssertNil(store.activeRun)
  }

  @MainActor func testSettingsAndUnavailableCommandsCannotConsumeDraft() {
    let store = WorkspaceStore()
    store.draft = "/files"
    store.selectComposerCommand(.files)
    XCTAssertEqual(store.draft, "/files")
    XCTAssertFalse(store.showingFileSearch)
    XCTAssertTrue(store.handleComposerCommand())
    XCTAssertEqual(store.draft, "/files")
    XCTAssertNotNil(store.error)
    store.openSettings()
    store.selectComposerCommand(.new)
    XCTAssertEqual(store.destination, .settings)
    XCTAssertEqual(store.draft, "/files")
    XCTAssertTrue(store.enabledComposerCommands.isEmpty)
  }

  @MainActor func testModelCommandOpensMainWindowSettingsWithoutFocusingHiddenComposer() {
    let store = WorkspaceStore()
    let focus = store.focusComposer
    store.selectComposerCommand(.model)
    XCTAssertEqual(store.destination, .settings)
    XCTAssertEqual(store.settingsPage, .model)
    XCTAssertEqual(store.focusComposer, focus)
    XCTAssertEqual(store.draft, "")
  }

  @MainActor func testFileCommandUsesGlobalPresentation() {
    let store = WorkspaceStore()
    store.project = URL(fileURLWithPath: "/project")
    store.selectComposerCommand(.files)
    XCTAssertEqual(store.presentedOverlay, .fileSearch)
    XCTAssertEqual(store.draft, "")
    XCTAssertEqual(store.destination, .workspace)
  }

  @MainActor func testReviewCommandOpensModelReviewChoicesWithoutTogglingDiffPanel() {
    let store = WorkspaceStore()
    store.project = URL(fileURLWithPath: "/project")
    store.draft = "/review"

    XCTAssertTrue(store.handleComposerCommand())
    XCTAssertEqual(store.draft, "")
    XCTAssertTrue(store.showingReviewMode)
    XCTAssertEqual(store.reviewModeProject, "/project")
    XCTAssertFalse(store.showingInspector)
    XCTAssertNil(store.activeWorkspaceContentTab)

    store.dismissCodeReviewMode()
    store.selectComposerCommand(.review)
    XCTAssertTrue(store.showingReviewMode)
    XCTAssertFalse(store.showingInspector)
  }
}
