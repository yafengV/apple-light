import XCTest
@testable import ShipiOS

final class CopyLocationTests: XCTestCase {
  func testFocusChoosesURLOrWorkingDirectoryWithoutFallback() throws {
    let url = try XCTUnwrap(URL(string: "https://example.com/page?q=1"))
    XCTAssertEqual(CopyLocationTarget.resolve(browserFocused: true, browserURL: url,
      workingDirectory: "/Projects/App"), .browser(url))
    XCTAssertEqual(CopyLocationTarget.resolve(browserFocused: false, browserURL: url,
      workingDirectory: "/Projects/App"), .directory("/Projects/App"))
    XCTAssertNil(CopyLocationTarget.resolve(browserFocused: true, browserURL: nil,
      workingDirectory: "/Projects/App"), "A browser without a loaded URL must not copy another context")
    XCTAssertNil(CopyLocationTarget.resolve(browserFocused: false, browserURL: url,
      workingDirectory: nil))
    XCTAssertNil(CopyLocationTarget.resolve(browserFocused: false, browserURL: nil,
      workingDirectory: "relative/path"))
    XCTAssertEqual(CopyLocationTarget.browser(url).text, url.absoluteString)
    XCTAssertEqual(CopyLocationTarget.directory("/Projects/App").text, "/Projects/App")
    XCTAssertEqual(CopyLocationTarget.browser(url).menuTitle, "复制浏览器网址")
    XCTAssertEqual(CopyLocationTarget.directory("/Projects/App").menuTitle, "复制工作目录")
  }

  @MainActor func testWorkspaceCommandRequiresCopyableContext() {
    let store = WorkspaceStore()
    defer { store.workspace.browser.shutdown() }
    XCTAssertFalse(store.commandEnabled("copy-location"))
    store.project = URL(fileURLWithPath: "/Projects/App")
    XCTAssertTrue(store.commandEnabled("copy-location"))
    XCTAssertEqual(store.copyLocationTarget, .directory("/Projects/App"))
    store.library.tasks = [.init(id: "other", project: "/Projects/Other", title: "Other", runIDs: [])]
    store.selection = "other"
    XCTAssertFalse(store.commandEnabled("copy-location"), "A pending scope switch must not copy the previous project")
    store.selection = nil
    store.openSettings(.general)
    XCTAssertFalse(store.commandEnabled("copy-location"))
  }
}
