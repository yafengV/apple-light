import XCTest

@testable import ShipiOS

final class MessageDocumentTests: XCTestCase {
  func testFencedCodePreservesWhitespaceAndDoesNotParseMarkdownInside() throws {
    let input = "## 示例\n\n```swift\n  let text = \"**原样**\"\n\nprint(text)\n```\n\n完成。"
    let blocks = MessageDocument.parse(input)
    XCTAssertEqual(blocks.count, 3)
    XCTAssertEqual(blocks[0].kind, .heading(2))
    XCTAssertEqual(blocks[1].kind, .code("swift"))
    XCTAssertEqual(blocks[1].source, "  let text = \"**原样**\"\n\nprint(text)\n")
    XCTAssertEqual(String(blocks[2].text.characters), "完成。")
  }

  func testIncompleteStreamingFenceBecomesOneCodeBlockWithStableIdentity() {
    let partial = MessageDocument.parse("先看代码：\n\n~~~swift\nlet a =")
    let completed = MessageDocument.parse("先看代码：\n\n~~~swift\nlet a = 1\n~~~\n\n后续")
    XCTAssertEqual(partial.count, 2)
    XCTAssertEqual(partial[1].kind, .code("swift"))
    XCTAssertEqual(partial[1].id, completed[1].id)
    XCTAssertEqual(completed[1].source, "let a = 1\n")
    XCTAssertEqual(completed.count, 3)
  }

  func testNestedListsCheckboxesQuotesAndNonOneStart() throws {
    let blocks = MessageDocument.parse(
      "3. 第一项\n   - 子项\n4. 第二项\n\n- [x] 完成\n- [ ] 待办\n\n> 引用\n>\n> 第二段")
    XCTAssertEqual(blocks[0].children[0].kind, .item("3.", nil))
    XCTAssertEqual(blocks[0].children[1].kind, .item("4.", nil))
    XCTAssertEqual(blocks[0].children[0].children[1].kind, .list)
    XCTAssertEqual(blocks[1].children[0].kind, .item("•", true))
    XCTAssertEqual(blocks[1].children[1].kind, .item("•", false))
    XCTAssertEqual(blocks[2].kind, .quote)
    XCTAssertEqual(blocks[2].children.count, 2)
  }

  func testTableEscapedPipesAndAlignment() throws {
    let table = try XCTUnwrap(
      MessageDocument.parse("| 项目 | 数量 |\n| :--- | ---: |\n| a\\|b | **2** |\n").first)
    XCTAssertEqual(table.kind, .table)
    XCTAssertEqual(table.alignments, [-1, 1])
    XCTAssertEqual(table.rows.count, 2)
    XCTAssertEqual(String(table.rows[1][0].characters), "a|b")
    XCTAssertTrue(
      table.rows[1][1].runs.first!.inlinePresentationIntent!.contains(.stronglyEmphasized))
  }

  func testInlineFormattingLinksAndLiteralHTML() throws {
    let blocks = MessageDocument.parse(
      "**粗体与 *斜体*** `代码` ~~删除~~ [官网](https://example.com/a?q=1&b=2)\n\n<script>alert(1)</script>")
    let runs = Array(blocks[0].text.runs)
    XCTAssertTrue(
      runs.contains {
        $0.inlinePresentationIntent?.contains([.stronglyEmphasized, .emphasized]) == true
      })
    XCTAssertTrue(runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
    XCTAssertTrue(runs.contains { $0.inlinePresentationIntent?.contains(.strikethrough) == true })
    XCTAssertTrue(runs.contains { $0.link?.host == "example.com" })
    XCTAssertEqual(blocks[1].kind, .code("html"))
    XCTAssertTrue(blocks[1].source.contains("<script>"))
  }

  func testFileLinksDecodeUnicodeSpacesAndBothLineFormats() throws {
    let root = URL(fileURLWithPath: "/tmp/message-project")
    for target in [
      "Sources/测试%20文件.swift:42", "/tmp/message-project/Sources/测试%20文件.swift#L42",
      "file:///tmp/message-project/Sources/测试%20文件.swift:42", "file.swift:12",
    ] {
      let expected: MessageLink.Target =
        target == "file.swift:12"
        ? .file(path: "file.swift", line: 12) : .file(path: "Sources/测试 文件.swift", line: 42)
      XCTAssertEqual(
        try MessageLink.target(XCTUnwrap(MessageLink.url(target)), root: root), expected)
    }
  }

  func testExternalLinksAndUnsafeLocalDestinations() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createSymbolicLink(
      atPath: root.appendingPathComponent("escape").path, withDestinationPath: "/tmp")
    for target in [
      "javascript:alert(1)", "data:text/html,hello", "../outside.txt", "/etc/passwd",
      "file://remote/a", "escape/outside.txt", "file.swift:0",
    ] {
      XCTAssertThrowsError(
        try MessageLink.target(XCTUnwrap(MessageLink.url(target)), root: root), target)
    }
    let web = try XCTUnwrap(URL(string: "https://example.com/a#b"))
    XCTAssertEqual(try MessageLink.target(web, root: root), .web(web))
  }
}
