import XCTest
@testable import ShipiOS

final class TaskExternalResourceProviderTests: XCTestCase {
  func testKnownHostsProvideNamesWithoutAcceptingLookalikeDomains() {
    XCTAssertEqual(TaskExternalResourceProvider.identify(
      "https://docs.google.com/document/d/abc/edit")?.name, "Google Drive")
    XCTAssertEqual(TaskExternalResourceProvider.identify(
      "https://app.notion.com/page")?.name, "Notion")
    XCTAssertEqual(TaskExternalResourceProvider.identify(
      "https://linear.app/team/issue/ABC-1")?.name, "Linear")
    XCTAssertEqual(TaskExternalResourceProvider.identify(
      "https://www.figma.com/file/abc")?.name, "Figma")
    XCTAssertEqual(TaskExternalResourceProvider.identify(
      "https://github.com/org/repo")?.name, "GitHub")
    XCTAssertNil(TaskExternalResourceProvider.identify("https://docs.google.com.evil.test/"))
  }

  func testProvidedAndReadSourcePresentation() {
    let url = "https://docs.google.com/document/d/abc/edit"
    let provided = TaskExternalSource(resource: .init(title: "Plan", url: url),
      activities: [.provided], providerName: "Google Drive", providerID: "google-drive")
    XCTAssertNil(provided.detail)
    XCTAssertEqual(provided.iconName, "link")
    let read = TaskExternalSource(resource: .init(title: "Plan", url: url),
      activities: [.read], providerName: "Google Drive", providerID: "google-drive")
    XCTAssertEqual(read.detail, "Google Drive · \(url)")
    XCTAssertEqual(read.iconName, "doc.text")
  }

  func testSiteToolAttachesOnlyToHostnameTitledResource() {
    let url = "https://example.test/guide"
    let hostname = TaskExternalSource(resource: .init(title: "example.test", url: url),
      activities: [.read])
    XCTAssertEqual(hostname.siteToolHost, "example.test")
    let titled = TaskExternalSource(resource: .init(title: "Guide", url: url),
      activities: [.read])
    XCTAssertNil(titled.siteToolHost)
  }
}
