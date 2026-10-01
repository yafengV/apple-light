import XCTest
@testable import ShipiOS

final class TaskExternalResourceIdentityTests: XCTestCase {
  func testKnownDocumentProvidersUseStableURLIdentity() {
    XCTAssertEqual(TaskExternalResourceIdentity.canonicalKey(
      "https://docs.google.com/document/d/abc123/edit?usp=sharing"),
      "google:document:abc123")
    XCTAssertEqual(TaskExternalResourceIdentity.canonicalKey(
      "https://sheets.google.com/spreadsheets/d/sheet-id/view"),
      "google:spreadsheet:sheet-id")
    XCTAssertEqual(TaskExternalResourceIdentity.canonicalKey(
      "https://drive.google.com/file/d/file-id/view"), "google:drive:file-id")
    XCTAssertEqual(TaskExternalResourceIdentity.canonicalKey(
      "https://drive.google.com/open?id=file-id"), "google:drive:file-id")
    XCTAssertEqual(TaskExternalResourceIdentity.canonicalKey(
      "https://www.notion.so/Team-12345678-1234-1234-1234-123456789abc"),
      "notion:12345678123412341234123456789abc")
    XCTAssertEqual(TaskExternalResourceIdentity.canonicalKey(
      "https://linear.app/MyTeam/issue/ABC-123/title"), "linear:myteam:issue:ABC-123")
    XCTAssertEqual(TaskExternalResourceIdentity.canonicalKey(
      "https://www.figma.com/design/FIGMA123/file"), "figma:FIGMA123")
    XCTAssertNil(TaskExternalResourceIdentity.canonicalKey("https://example.test/document"))
    XCTAssertNil(TaskExternalResourceIdentity.canonicalKey("https://user:pass@figma.com/file/x"))
  }
}
