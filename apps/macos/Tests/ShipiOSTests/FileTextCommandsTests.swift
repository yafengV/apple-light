import XCTest
@testable import ShipiOS

final class FileTextCommandsTests: XCTestCase {
  private func result(_ command: FileTextCommand, _ source: String,
    selection: NSRange, path: String = "Example.swift") -> (String, NSRange)? {
    guard let edit = FileTextCommands.edit(command, in: source, selection: selection, path: path) else { return nil }
    return ((source as NSString).replacingCharacters(in: edit.range, with: edit.replacement), edit.selection)
  }

  func testIndentOutdentAndCommentPreserveUnicodeAndCRLF() {
    let source = "👩🏽‍💻 first\r\n  second\r\n"
    let full = NSRange(location: 0, length: (source as NSString).length)
    let indented = result(.indentLines, source, selection: full)!
    XCTAssertEqual(indented.0, "  👩🏽‍💻 first\r\n    second\r\n")
    XCTAssertEqual(result(.outdentLines, indented.0, selection: indented.1)?.0, source)
    let commented = result(.toggleLineComment, source, selection: full)!
    XCTAssertEqual(commented.0, "// 👩🏽‍💻 first\r\n  // second\r\n")
    XCTAssertEqual(result(.toggleLineComment, commented.0, selection: commented.1)?.0, source)
  }

  func testLineMoveAndCopyHandleFinalLineWithoutNewline() {
    let source = "one\ntwo\nthree"
    let caret = NSRange(location: 5, length: 0)
    XCTAssertEqual(result(.moveUp, source, selection: caret)?.0, "two\none\nthree")
    XCTAssertEqual(result(.moveDown, source, selection: caret)?.0, "one\nthree\ntwo")
    XCTAssertEqual(result(.copyUp, source, selection: caret)?.0, "one\ntwo\ntwo\nthree")
    XCTAssertEqual(result(.copyDown, source, selection: caret)?.0, "one\ntwo\ntwo\nthree")
    XCTAssertEqual(result(.copyUp, source, selection: NSRange(location: 9, length: 0))?.0,
      "one\ntwo\nthree\nthree")
    XCTAssertEqual(result(.copyDown, source, selection: NSRange(location: 9, length: 0))?.0,
      "one\ntwo\nthree\nthree")
    XCTAssertNil(result(.moveUp, source, selection: NSRange(location: 0, length: 0)))
    XCTAssertNil(result(.moveDown, source, selection: NSRange(location: 10, length: 0)))
    let movedToFinalLine = result(.moveDown, "a\nb", selection: NSRange(location: 0, length: 2))!
    XCTAssertEqual(movedToFinalLine.0, "b\na")
    XCTAssertLessThanOrEqual(NSMaxRange(movedToFinalLine.1), (movedToFinalLine.0 as NSString).length)
  }

  func testBlankLineBlockCommentAndLanguageCommentSyntax() {
    let source = "a\nb"
    let blank = result(.insertBlankLine, source, selection: NSRange(location: 0, length: 0))!
    XCTAssertEqual(blank.0, "a\n\nb")
    XCTAssertEqual(blank.1, NSRange(location: 2, length: 0))
    XCTAssertEqual(result(.insertIndent, "a", selection: NSRange(location: 1, length: 0))?.0, "a ")
    XCTAssertEqual(result(.insertIndent, "ab", selection: NSRange(location: 2, length: 0))?.0, "ab  ")
    let block = result(.toggleBlockComment, source, selection: NSRange(location: 0, length: 1))!
    XCTAssertEqual(block.0, "/*a*/\nb")
    XCTAssertEqual(result(.toggleBlockComment, block.0, selection: block.1)?.0, source)
    XCTAssertEqual(result(.toggleBlockComment, block.0,
      selection: NSRange(location: 0, length: 5))?.0, source)
    XCTAssertEqual(result(.toggleLineComment, "  echo hi", selection: NSRange(location: 4, length: 0),
      path: "script.sh")?.0, "  # echo hi")
    XCTAssertEqual(result(.toggleLineComment, "text", selection: NSRange(location: 0, length: 0),
      path: "README.md")?.0, "<!--text-->")
    XCTAssertEqual(result(.toggleLineComment, "color: red;", selection: NSRange(location: 0, length: 0),
      path: "site.css")?.0, "/*color: red;*/")
  }
}
