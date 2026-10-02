import XCTest
@testable import ShipiOS

final class ReviewFileJumpTests: XCTestCase {
  private let paths = ["z/Same.swift", "a/Same.swift", "Sources/Alpha.swift", "Root.swift"]

  func testEmptyQuerySortsByFileNameThenParent() {
    XCTAssertEqual(ReviewFileJump.matches(paths: paths, query: "").map(\.path),
      ["Sources/Alpha.swift", "Root.swift", "a/Same.swift", "z/Same.swift"])
  }

  func testFilenameAndPathFuzzySearch() {
    XCTAssertEqual(ReviewFileJump.matches(paths: paths, query: "Same").map(\.path),
      ["a/Same.swift", "z/Same.swift"])
    XCTAssertEqual(ReviewFileJump.matches(paths: paths, query: "Sources/Alpha").map(\.path),
      ["Sources/Alpha.swift"])
    XCTAssertTrue(ReviewFileJump.matches(paths: paths, query: "not-a-file").isEmpty)
  }

  func testLocalReviewTargetUsesItsRenderedAnchorAndCollapseKey() {
    let root = URL(fileURLWithPath: "/tmp/review-fixture")
    let file = GitFile(path: "Sources/Alpha.swift", staged: false, unstaged: true, untracked: false)
    let target = ReviewFileJump.target(path: file.path, scope: .unstaged, root: root,
      selection: "unstaged:main", revision: "-- src", files: [file], lastTurn: nil)
    XCTAssertEqual(target?.anchor, root.path + ":unstaged:main:Sources/Alpha.swift")
    XCTAssertEqual(target?.collapseKey, "unstaged:-- src:Sources/Alpha.swift")
    XCTAssertNil(ReviewFileJump.target(path: "missing.swift", scope: .unstaged, root: root,
      selection: "unstaged:main", revision: "-- src", files: [file], lastTurn: nil))
  }

  func testLastTurnTargetUsesRecordedFileIDWithoutRepositoryRoot() {
    let file = CodexTurnDiffFile(id: 7, path: "Sources/Alpha.swift", patch: "")
    let snapshot = LastTurnReviewSnapshot(source: .init(runID: "run-123", root: nil, diff: nil),
      unifiedDiff: "", files: [file], patches: [:])
    let target = ReviewFileJump.target(path: file.path, scope: .lastTurn, root: nil,
      selection: "lastTurn:", revision: "", files: [], lastTurn: snapshot)
    XCTAssertEqual(target?.anchor, "run-123:7")
    XCTAssertEqual(target?.collapseKey, "lastTurn:run-123:Sources/Alpha.swift")
  }
}
