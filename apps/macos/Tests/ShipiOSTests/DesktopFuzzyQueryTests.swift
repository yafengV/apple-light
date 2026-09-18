import XCTest
@testable import ShipiOS

final class DesktopFuzzyQueryTests: XCTestCase {
  struct Example: Decodable {
    struct Fragment: Decodable { let startOffset: Int; let endOffset: Int }
    let text: String
    let query: String
    let score: Int
    let ranges: [Fragment]?
  }

  func testScoresAndHighlightFragmentsAgainstDesktopReferenceExamples() throws {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "task-search-fuzzy", withExtension: "json", subdirectory: "Fixtures"))
    let examples = try JSONDecoder().decode([Example].self, from: Data(contentsOf: url))
    for example in examples {
      let result = DesktopFuzzyQuery(example.query).match(example.text)
      let context = "\(example.query.debugDescription) in \(example.text.debugDescription)"
      XCTAssertEqual(result?.score ?? 0, example.score, context)
      XCTAssertEqual(result?.ranges, example.ranges.map { $0.map { NSRange(location: $0.startOffset, length: $0.endOffset - $0.startOffset) } }, context)
    }
  }

  func testTaskRankingUsesFieldsThenDegreeThenUpdatedTimeAndSupportsIDAndPath() {
    func task(_ id: String, title: String = "Other", date: Double = 0, project: String = "/else") -> WorkspaceTask {
      .init(id: id, project: project, title: title, runIDs: [id], updatedAt: Date(timeIntervalSince1970: date))
    }
    let tasks = [task("project", date: 900, project: "/Needle"), task("branch", date: 800),
      task("content", date: 700), task("long", title: "Needle and more", date: 600),
      task("older", title: "Needle", date: 1), task("newer", title: "Needle", date: 2)]
    var request = TaskSearchRequest(query: "needle", tasks: tasks, names: [:],
      notes: ["content": "Needle"], branches: ["branch": "Needle"], runs: [])
    XCTAssertEqual(request.search().map(\.id), ["newer", "older", "long", "content", "branch", "project"])
    request.includeContentResults = false
    XCTAssertEqual(request.search().map(\.id), ["newer", "older", "long", "branch", "project"])
    let idTask = task("abcdef12-3456", project: "/Users/Owner/DeepProject")
    request = .init(query: "ABCDEF12", tasks: [idTask], names: [:], notes: [:], branches: [:], runs: [])
    XCTAssertEqual(request.search().map(\.id), [idTask.id])
    request = .init(query: "abcdef1", tasks: [idTask], names: [:], notes: [:], branches: [:], runs: [])
    XCTAssertTrue(request.search().isEmpty)
    request = .init(query: "Owner/DP", tasks: [idTask], names: [:], notes: [:], branches: [:], runs: [])
    XCTAssertEqual(request.search().map(\.id), [idTask.id])
  }

  func testContentOutranksBranchWithinTaskAndFuzzyExcerptKeepsAllFragments() {
    let task = WorkspaceTask(id: "task", project: "", title: "Other", runIDs: ["old", "new"])
    let request = TaskSearchRequest(query: "cpv", tasks: [task], names: [:],
      notes: ["old": "Edit CommandPaletteView"], branches: ["new": "cpv"], runs: [])
    XCTAssertEqual(request.search().first?.source, "消息")
    let text = "Before " + String(repeating: "🙂", count: 80) + "Hello " + String(repeating: "x", count: 140) + " World" + String(repeating: "!", count: 120)
    let snippet = TaskSearchRequest.excerpt(text, query: "hw")
    XCTAssertNotNil(DesktopFuzzyQuery("hw").match(snippet))
    XCTAssertTrue(snippet.contains("Hello")); XCTAssertTrue(snippet.contains("World"))
  }

  func testCommandSearchMatchesSeparatedFragmentsAndRanksExactTitleFirst() {
    XCTAssertEqual(DesktopCommand.search(query: "设置").first?.id, "settings")
    XCTAssertTrue(DesktopCommand.search(query: "搜索 文").contains { $0.id == "files" })
    XCTAssertEqual(DesktopCommand.search(query: " \n ").map(\.id), DesktopCommand.all.map(\.id))
    XCTAssertTrue(DesktopCommand.search(query: "missing-command-xyz").isEmpty)
  }
}
