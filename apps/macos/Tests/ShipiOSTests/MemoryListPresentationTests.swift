import XCTest
@testable import ShipiOS

final class MemoryListPresentationTests: XCTestCase {
  func testSearchHandlesSubstringLocationUnicodeAndTyposWithoutChangingSource() {
    let values = MemoryPreferences(items: [
      .init(text: "Project note: deploy to staging"), .init(text: "优先使用 SwiftUI"),
      .init(text: "Café ＡＢＣ"), .init(text: "unrelated")])
    func search(_ query: String) -> [String] {
      MemoryListPresentation(preferences: values, loaded: true, loading: false,
        query: query, sort: .newest).items.map(\.text)
    }
    XCTAssertEqual(search("  STAGING  "), [values.items[0].text])
    XCTAssertEqual(search("stagng"), [values.items[0].text])
    XCTAssertEqual(search("Swift"), [values.items[1].text])
    XCTAssertEqual(search("cafe abc"), [values.items[2].text])
    XCTAssertTrue(search("不存在的记忆内容").isEmpty)
    XCTAssertTrue(search(String(repeating: "z", count: 10000)).isEmpty)
    XCTAssertEqual(values.items.count, 4)
  }

  func testSortUsesUpdatedTimeWithDeterministicTiesAndFilteredItemsRemainSorted() {
    let first = SavedMemory(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      text: "same alpha", createdAt: .distantFuture, updatedAt: Date(timeIntervalSince1970: 1))
    let second = SavedMemory(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
      text: "same beta", createdAt: .distantPast, updatedAt: Date(timeIntervalSince1970: 2))
    let tie = SavedMemory(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
      text: "other", updatedAt: second.updatedAt)
    let preferences = MemoryPreferences(items: [tie, first, second])
    func list(_ sort: MemoryListSort, _ query: String = "") -> [UUID] {
      MemoryListPresentation(preferences: preferences, loaded: true, loading: false,
        query: query, sort: sort).items.map(\.id)
    }
    XCTAssertEqual(list(.newest), [second.id, tie.id, first.id])
    XCTAssertEqual(list(.oldest), [first.id, second.id, tie.id])
    XCTAssertEqual(list(.newest, "same"), [second.id, first.id])
  }

  func testLoadingAndFailureNeverExposeStaleRowsOrAnEmptySuccessState() {
    let preferences = MemoryPreferences(items: [.init(text: "cached")])
    for loaded in [true, false] {
      let presentation = MemoryListPresentation(preferences: preferences, loaded: loaded,
        loading: true, query: "", sort: .newest)
      XCTAssertEqual(presentation.state, .loading)
      XCTAssertTrue(presentation.items.isEmpty)
    }
    let failed = MemoryListPresentation(preferences: preferences, loaded: false,
      loading: false, query: "no match", sort: .newest)
    XCTAssertEqual(failed.state, .failed)
    XCTAssertTrue(failed.items.isEmpty)
    XCTAssertEqual(MemoryListPresentation(preferences: .init(), loaded: true,
      loading: false, query: "", sort: .newest).state, .empty)
    XCTAssertEqual(MemoryListPresentation(preferences: preferences, loaded: true,
      loading: false, query: "  nonexistent  ", sort: .newest).state, .noMatches("nonexistent"))
  }
}
