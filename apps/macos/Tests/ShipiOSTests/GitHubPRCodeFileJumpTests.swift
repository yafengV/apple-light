import XCTest
@testable import ShipiOS

final class GitHubPRCodeFileJumpTests: XCTestCase {
  private let paths = ["z/Same.swift", "a/Same.swift", "Sources/Alpha.swift", "Root.swift"]

  func testEmptyQuerySortsByFileNameThenParent() {
    XCTAssertEqual(GitHubPRCodeFileJump.matches(paths: paths, query: "").map(\.path),
      ["Sources/Alpha.swift", "Root.swift", "a/Same.swift", "z/Same.swift"])
  }

  func testFilenameAndPathFuzzySearch() {
    XCTAssertEqual(GitHubPRCodeFileJump.matches(paths: paths, query: "Same").map(\.path),
      ["a/Same.swift", "z/Same.swift"])
    XCTAssertEqual(GitHubPRCodeFileJump.matches(paths: paths, query: "Sources/Alpha").map(\.path),
      ["Sources/Alpha.swift"])
    XCTAssertTrue(GitHubPRCodeFileJump.matches(paths: paths, query: "not-a-file").isEmpty)
  }
}
