import XCTest

@testable import ShipiOS

@MainActor final class TaskSummaryBrowserTabTests: XCTestCase {
  func testOnlyLiveTaskOwnedWebPagesAppearInSummary() {
    let session = BrowserSession()
    defer { session.shutdown() }
    let owned = session.newTab()
    owned.address = "https://example.com/docs"
    let foreign = session.newTab()
    foreign.address = "https://other.example/"
    let blank = session.newTab()
    let invalid = session.newTab()
    invalid.address = "file:///private/secrets"

    let contentTabs: [WorkspaceContentTab] = [
      .browser(owned.id, owner: "task"),
      .browser(owned.id, owner: "task"),
      .browser(foreign.id, owner: "other"),
      .browser(blank.id, owner: "task"),
      .browser(invalid.id, owner: "task"),
    ]
    let visible = TaskSummaryBrowserTabs.collect(owner: "task",
      contentTabs: contentTabs, browserTabs: session.tabs)
    XCTAssertEqual(visible.map(\.id), [owned.id])
    XCTAssertEqual(visible.first?.title, "example.com")
    XCTAssertEqual(visible.first?.subtitle, "example.com")

    session.close(owned.id)
    XCTAssertTrue(TaskSummaryBrowserTabs.collect(owner: "task",
      contentTabs: contentTabs, browserTabs: session.tabs).isEmpty)
  }
}
