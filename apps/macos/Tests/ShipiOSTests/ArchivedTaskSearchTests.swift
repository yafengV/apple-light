import XCTest
@testable import ShipiOS

final class ArchivedTaskSearchTests: XCTestCase {
  func testOfficialFuseReferenceCases() throws {
    struct Case: Decodable { let query: String; let fields: [String]; let matches: Bool }
    let url = try XCTUnwrap(Bundle.module.url(forResource: "archive-search-fuse-7.1.0",
      withExtension: "json", subdirectory: "Fixtures"))
    let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
    XCTAssertGreaterThan(cases.count, 500)
    for item in cases {
      XCTAssertEqual(ArchivedTaskSearch(item.query).matches(item.fields), item.matches,
        "query=\(item.query.debugDescription), fields=\(item.fields)")
    }
  }

  func testSearchDoesNotJoinFieldsStripAccentsOrMatchParentPath() {
    XCTAssertFalse(ArchivedTaskSearch("alpha same").matches(["Alpha", "Same"]))
    XCTAssertFalse(ArchivedTaskSearch("e").matches(["é"]))
    XCTAssertTrue(ArchivedTaskSearch("设置页免").matches(["设置页面交互"]))
    XCTAssertTrue(ArchivedTaskSearch("alhpa").matches(["Alpha"]))
    XCTAssertTrue(ArchivedTaskSearch("needle").matches([String(repeating: "x", count: 500) + "needle"]))
    var library = WorkspaceLibrary()
    library.tasks = [.init(id: "one", project: "/privateunique/folder/project", title: "Hello", runIDs: [], archived: true)]
    let value = ArchivedTaskPresentation(library: library)
    XCTAssertTrue(value.groups(query: "privateunique", project: .all, kind: .all, sort: .updated).isEmpty)
    XCTAssertEqual(value.groups(query: "projet", project: .all, kind: .all, sort: .updated).first?.entries.count, 1)
  }
}
