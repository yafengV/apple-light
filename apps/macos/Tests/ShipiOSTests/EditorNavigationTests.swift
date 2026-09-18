import XCTest

@testable import ShipiOS

final class EditorNavigationTests: XCTestCase {
  func testXcodeUsesArgumentsWithoutShellExpansion() throws {
    let file = URL(fileURLWithPath: "/tmp/space #$(touch sentinel); quote' 中文.swift")
    XCTAssertEqual(
      try EditorOpenRequest.make(editor: .xcode, file: file, line: 42),
      .command("/usr/bin/xcrun", ["xed", "--line", "42", file.path]))
    XCTAssertEqual(
      try EditorOpenRequest.make(editor: .xcode, file: file, line: nil),
      .command("/usr/bin/xcrun", ["xed", file.path]))
    XCTAssertThrowsError(try EditorOpenRequest.make(editor: .xcode, file: file, line: 0))
    XCTAssertThrowsError(try EditorOpenRequest.make(editor: .xcode, file: file, line: -1))
  }

  func testVSCodeURLPreservesSpecialCharactersAndLine() throws {
    let file = URL(fileURLWithPath: "/tmp/hello #?%:42\n中文.swift")
    let request = try EditorOpenRequest.make(editor: .vscode, file: file, line: 12)
    guard case .appURL(let url, let bundleID) = request else {
      return XCTFail("Expected editor URL")
    }
    let parsed = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    XCTAssertEqual(parsed.path, file.path + ":12:1")
    XCTAssertEqual(parsed.scheme, "vscode")
    XCTAssertEqual(parsed.host, "file")
    XCTAssertNil(parsed.query)
    XCTAssertNil(parsed.fragment)
    XCTAssertEqual(bundleID, "com.microsoft.VSCode")
  }

  @MainActor func testPreferenceSurvivesLibraryRoundTripAndSettingsNavigation() throws {
    let store = WorkspaceStore()
    store.library = try JSONDecoder().decode(WorkspaceLibrary.self, from: Data("{}".utf8))
    XCTAssertEqual(store.preferredEditor, .system)
    store.openSettings(.general)
    store.preferredEditor = .xcode
    store.closeSettings()
    let library = try JSONDecoder().decode(
      WorkspaceLibrary.self, from: JSONEncoder().encode(store.library))
    XCTAssertEqual(library.preferredEditor, ExternalEditor.xcode.rawValue)
    store.library.preferredEditor = "future-editor"
    XCTAssertEqual(store.preferredEditor, .system)
    XCTAssertEqual(store.destination, .workspace)
  }

  func testSystemDefaultDoesNotPretendToSupportLinesAndDeletionMapsForward() throws {
    let file = URL(fileURLWithPath: "/tmp/file.swift")
    XCTAssertEqual(try EditorOpenRequest.make(editor: .system, file: file, line: nil), .file(file))
    XCTAssertThrowsError(try EditorOpenRequest.make(editor: .system, file: file, line: 7))
    let diff = ReviewDiff("@@ -7,3 +7,2 @@\n keep\n-remove\n next\n")
    let removed = try XCTUnwrap(diff.lines.first { $0.kind == .deletion })
    XCTAssertEqual(removed.oldLine, 8)
    XCTAssertNil(removed.newLine)
    XCTAssertEqual(removed.workingLine, 8)
  }
}
