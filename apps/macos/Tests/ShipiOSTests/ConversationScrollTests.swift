import XCTest

@testable import ShipiOS

final class ConversationScrollTests: XCTestCase {
  private func metrics(_ offset: Double, height: Double = 1200, viewport: Double = 500)
    -> ConversationScrollMetrics
  {
    .init(offset: offset, contentHeight: height, viewportHeight: viewport)
  }

  func testInitialAndDelayedMarkdownLayoutFollowLatest() {
    var state = ConversationScrollState()
    XCTAssertFalse(state.observe(metrics(0, height: 0, viewport: 0)))
    XCTAssertTrue(state.observe(metrics(0)))
    XCTAssertFalse(state.observe(metrics(700)))
    XCTAssertTrue(state.contentChanged())
    XCTAssertTrue(state.observe(metrics(700, height: 1500)))
    XCTAssertTrue(state.followsLatest)
    XCTAssertFalse(state.observe(metrics(1000, height: 1500)))
    XCTAssertTrue(state.isAtBottom)
    XCTAssertFalse(state.hasNewContent)
  }

  func testLiveScrollOverridesPendingFollowAndContentNeverPullsReaderBack() {
    var state = ConversationScrollState()
    _ = state.observe(metrics(700))
    state.beginUserScroll()
    XCTAssertFalse(state.observe(metrics(350)))
    XCTAssertFalse(state.contentChanged())
    XCTAssertFalse(state.observe(metrics(350, height: 1800)))
    state.endUserScroll(metrics(350, height: 1800))
    XCTAssertFalse(state.followsLatest)
    XCTAssertTrue(state.hasNewContent)
    state.requestLatest()
    XCTAssertTrue(state.observe(metrics(350, height: 1800)))
    // Even while a jump is pending, a new user scroll takes priority.
    state.beginUserScroll()
    XCTAssertFalse(state.observe(metrics(200, height: 1800)))
    state.endUserScroll(metrics(200, height: 1800))
    XCTAssertFalse(state.followsLatest)
  }

  func testScrollbarAndKeyboardDetachWithoutLiveScrollNotification() {
    var state = ConversationScrollState()
    _ = state.observe(metrics(700))
    XCTAssertFalse(state.observe(metrics(150)))
    XCTAssertFalse(state.contentChanged())
    XCTAssertTrue(state.hasNewContent)
    XCTAssertFalse(state.observe(metrics(700)))
    XCTAssertTrue(state.followsLatest)
    XCTAssertFalse(state.hasNewContent)
  }

  func testResizeDoesNotLookLikeUserScrollingAndShortContentHasNoJumpButton() {
    var state = ConversationScrollState()
    _ = state.observe(metrics(700))
    XCTAssertTrue(state.observe(metrics(700, viewport: 300)))
    _ = state.observe(metrics(900, viewport: 300))
    XCTAssertTrue(state.followsLatest)
    XCTAssertFalse(state.observe(metrics(0, height: 200, viewport: 500)))
    XCTAssertTrue(state.isAtBottom)
  }

  func testFindPausesStreamingUntilUserReturnsToBottom() {
    var state = ConversationScrollState()
    _ = state.observe(metrics(700))
    state.pauseFollowing()
    XCTAssertFalse(state.observe(metrics(100)))
    XCTAssertFalse(state.contentChanged())
    XCTAssertFalse(state.observe(metrics(100, height: 1500)))
    XCTAssertTrue(state.hasNewContent)
    state.requestLatest()
    XCTAssertFalse(state.observe(metrics(1000, height: 1500)))
    XCTAssertTrue(state.followsLatest)
    XCTAssertFalse(state.hasNewContent)
  }

  @MainActor func testFindPreviousWrapsAndSingleResultCanBeLocatedAgain() async {
    let store = WorkspaceStore()
    let first = AgentRun(
      id: "first", kind: "chat", project: "/qa", status: "succeeded", createdAt: 0,
      updatedAt: 1, request: .null, result: .object(["response": .string("needle")]))
    let second = AgentRun(
      id: "second", kind: "chat", project: "/qa", status: "succeeded", createdAt: 1,
      updatedAt: 2, request: .null, result: .object(["response": .string("needle second")]))
    store.library.attach(first, to: nil, note: "one")
    store.library.attach(second, to: "first", note: "two")
    store.runs = [second, first]
    store.selection = first.id
    store.showingFind = true
    store.findText = "needle"
    await store.refreshFindMatches()
    store.executeCommand("find-previous")
    XCTAssertEqual(store.findIndex, 1)
    store.executeCommand("find-next")
    XCTAssertEqual(store.findIndex, 0)
    store.findText = "needle second"
    await store.refreshFindMatches()
    let previous = store.findRequest
    store.executeCommand("find-previous")
    XCTAssertEqual(store.findIndex, 0)
    XCTAssertNotEqual(store.findRequest, previous)
    store.findText = "no such match"
    await store.refreshFindMatches()
    XCTAssertFalse(store.commandEnabled("find-previous"))
    let request = store.findRequest
    store.executeCommand("find-next")
    XCTAssertEqual(store.findRequest, request)
  }

  func testPendingFindDoesNotResumeDuringIntermediateBottomLayout() {
    var state = ConversationScrollState()
    _ = state.observe(metrics(700))
    state.pauseFollowing()
    // A pre-navigation geometry callback may arrive before scrollTo takes effect.
    XCTAssertFalse(state.observe(metrics(700)))
    XCTAssertFalse(state.contentChanged())
    XCTAssertFalse(state.observe(metrics(100)))
    state.endNavigation()
    XCTAssertFalse(state.followsLatest)
    state.beginUserScroll()
    state.endUserScroll(metrics(700))
    XCTAssertTrue(state.followsLatest)
    state.pauseFollowing()
    state.endNavigation()
    XCTAssertTrue(state.followsLatest)
  }
}
