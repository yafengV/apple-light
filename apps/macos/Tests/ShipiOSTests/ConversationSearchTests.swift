import SwiftUI
import XCTest

@testable import ShipiOS

final class ConversationSearchTests: XCTestCase {
  private func input(_ source: String, prompt: String = "", plain: [String: String] = [:])
    -> ConversationSearchInput
  {
    .init(run: "run", prompt: prompt, markdown: source, plain: plain)
  }

  func testEveryOccurrenceInOneParagraphAndPromptIsIndependent() {
    let found = ConversationSearch.find(
      [input("needle NEEDLE needle", prompt: "needle")], query: "needle")
    XCTAssertEqual(found.count, 4)
    XCTAssertEqual(Set(found.map(\.id)).count, 4)
    XCTAssertEqual(found.map(\.textID.part), ["prompt", "response.0", "response.0", "response.0"])
    XCTAssertEqual(found.map(\.range.location), [0, 0, 7, 14])
  }

  func testSearchUsesRenderedMarkdownAndPreservesNestedSegmentIDs() {
    let source = """
      # **Needle**

      [shown](https://example.com/needle)

      > quoted needle

      - list needle

      ```swift
      let needle = 1
      ```

      | Name | Value |
      | --- | --- |
      | needle | NEEDLE |
      """
    let found = ConversationSearch.find([input(source)], query: "needle")
    XCTAssertEqual(found.count, 6)
    XCTAssertEqual(
      found.map(\.textID.part),
      [
        "response.0", "response.2.0", "response.3.0.0", "response.4",
        "response.5.cell.1.0", "response.5.cell.1.1",
      ])
    XCTAssertTrue(ConversationSearch.find([input(source)], query: "**Needle**").isEmpty)
    XCTAssertTrue(ConversationSearch.find([input(source)], query: "example.com").isEmpty)
  }

  func testUnicodeCaseFoldingAndCanonicalAccentsUseValidUTF16Ranges() {
    let text = "🧑🏽‍💻 中文 中文 Café Cafe\u{301}"
    let ranges = ConversationSearch.ranges(in: text, query: "中文")
    XCTAssertEqual(ranges.count, 2)
    for range in ranges { XCTAssertEqual((text as NSString).substring(with: range), "中文") }
    XCTAssertEqual(ConversationSearch.ranges(in: text, query: "CAFÉ").count, 2)
    XCTAssertTrue(ConversationSearch.ranges(in: text, query: "").isEmpty)
    XCTAssertEqual(
      ConversationSearch.ranges(in: "aaa", query: "aa"), [NSRange(location: 0, length: 2)])
  }

  func testHighlightPreservesLinksFormattingAndPlainText() throws {
    let original = try XCTUnwrap(
      MessageDocument.parse("[**needle**](https://example.com) needle").first
    ).text
    let highlighted = ConversationHighlight.apply(
      original, query: "needle", activeRange: NSRange(location: 7, length: 6))
    XCTAssertEqual(String(highlighted.characters), String(original.characters))
    XCTAssertTrue(highlighted.runs.contains { $0.link?.host == "example.com" })
    XCTAssertTrue(
      highlighted.runs.contains {
        $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
      })
    XCTAssertEqual(highlighted.runs.filter { $0.backgroundColor != nil }.count, 2)
    XCTAssertEqual(ConversationHighlight.apply(original, query: "", activeRange: nil), original)
  }

  @MainActor func testIndexIgnoresInvisibleJSONAndKeepsSelectionAsStreamGrows() async {
    let store = WorkspaceStore()
    let first = run("needle needle")
    store.library.attach(first, to: nil, note: "prompt")
    store.runs = [first]
    store.selection = first.id
    store.showingFind = true
    store.findText = "needle"
    await store.refreshFindMatches()
    XCTAssertEqual(store.findMatches.count, 2)
    store.moveFindMatch(1)
    let selected = store.activeFindMatch?.id
    let request = store.findRequest
    store.runs = [run("needle needle and another needle")]
    await store.refreshFindMatches()
    XCTAssertEqual(store.findMatches.count, 3)
    XCTAssertEqual(store.activeFindMatch?.id, selected)
    XCTAssertEqual(store.findRequest, request)
    store.selection = nil
    XCTAssertNil(store.activeFindMatch)
    XCTAssertFalse(store.commandEnabled("find-next"))
    store.selection = first.id
    store.findText = "hidden-field"
    XCTAssertFalse(store.commandEnabled("find-next"))
    await store.refreshFindMatches()
    XCTAssertTrue(store.findMatches.isEmpty)
    XCTAssertNil(store.activeFindMatch)
  }

  @MainActor func testCancelledIndexCannotLeaveSpinnerOrApplyResults() async {
    let store = WorkspaceStore()
    let run = run("needle")
    store.library.attach(run, to: nil, note: "prompt")
    store.runs = [run]
    store.selection = run.id
    store.showingFind = true
    store.findText = "needle"
    let indexing = Task { await store.refreshFindMatches() }
    indexing.cancel()
    await indexing.value
    XCTAssertFalse(store.finding)
    XCTAssertTrue(store.findMatches.isEmpty)
  }

  private func run(_ response: String) -> AgentRun {
    AgentRun(
      id: "run", kind: "chat", project: "/qa", status: "running", createdAt: 0, updatedAt: 1,
      request: .object(["model": .string("fixture")]),
      result: .object(["response": .string(response), "internal": .string("hidden-field")]))
  }
}
