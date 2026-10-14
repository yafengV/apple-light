import XCTest
@testable import ShipiOS

final class ReviewFileTreeTests: XCTestCase {
  func testFilterKeepsExactRecordedPathsAndTheirAncestors() {
    let paths = ["Sources/A/Same.swift", "Sources/B/Same.swift", "/other/同名.swift", "a space.swift"]
    let all = ReviewFileTreeNode.rows(ReviewFileTreeNode.tree(paths: paths + paths, query: ""), collapsed: [])
    XCTAssertEqual(Set(all.compactMap(\.node.path)), Set(paths))
    XCTAssertEqual(Set(all.map(\.id)).count, all.count)
    let filtered = ReviewFileTreeNode.rows(ReviewFileTreeNode.tree(paths: paths, query: "Sources/B"), collapsed: [])
    XCTAssertEqual(filtered.compactMap(\.node.path), ["Sources/B/Same.swift"])
    XCTAssertEqual(filtered.map(\.node.name), ["Sources", "B", "Same.swift"])
    XCTAssertTrue(ReviewFileTreeNode.tree(paths: paths, query: "missing").isEmpty)
  }

  func testDeletedFileAndAddedDirectoryWithSameNameDoNotLoseEitherPath() {
    let nodes = ReviewFileTreeNode.tree(paths: ["name", "name/child.swift"], query: "")
    let rows = ReviewFileTreeNode.rows(nodes, collapsed: [])
    XCTAssertEqual(Set(rows.compactMap(\.node.path)), ["name", "name/child.swift"])
    XCTAssertEqual(Set(rows.map(\.id)).count, 3)
    let collapsed = ReviewFileTreeNode.rows(nodes, collapsed: ["folder:name"])
    XCTAssertEqual(collapsed.compactMap(\.node.path), ["name"])
    XCTAssertEqual(rows.first { $0.node.path == "name/child.swift" }?.parentID, "folder:name")
  }
}
