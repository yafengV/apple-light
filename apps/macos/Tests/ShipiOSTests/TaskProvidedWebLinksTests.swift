import XCTest
@testable import ShipiOS

final class TaskProvidedWebLinksTests: XCTestCase {
  func testCollectsNamedAndBareWebLinksOutsideCode() {
    let sources = TaskProvidedWebLinks.collect("""
      阅读 [项目文档](https://example.test/docs) 和 https://example.test/guide。

      ```text
      https://example.test/secret
      ```

      `https://example.test/inline-code`
      [本地路径](file:///tmp/private)
      """)
    XCTAssertEqual(sources, [
      CodexWebSource(title: "项目文档", url: "https://example.test/docs"),
      CodexWebSource(title: "example.test", url: "https://example.test/guide"),
    ])
  }

  func testMergesEquivalentLinksWithinOneUserMessage() {
    XCTAssertEqual(TaskProvidedWebLinks.collect("""
      [Docs](https://example.test/docs/#intro) 和 https://example.test/docs
      """), [CodexWebSource(title: "Docs", url: "https://example.test/docs/#intro")])
  }
}
