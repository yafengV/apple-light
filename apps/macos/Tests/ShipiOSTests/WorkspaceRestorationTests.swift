import XCTest

@testable import ShipiOS

final class WorkspaceRestorationTests: XCTestCase {
  @MainActor func testEmptyDataRootDoesNotOpenGlobalLastProject() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = UserDefaults.standard
    let previous = defaults.object(forKey: "lastProject")
    defaults.set(FileManager.default.temporaryDirectory.path, forKey: "lastProject")
    defer {
      if let previous {
        defaults.set(previous, forKey: "lastProject")
      } else {
        defaults.removeObject(forKey: "lastProject")
      }
    }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    XCTAssertNil(store.project)
    XCTAssertFalse(store.restoringLibrary)
    XCTAssertFalse(store.busy)
    XCTAssertNil(store.error)
    XCTAssertTrue(store.library.projects.isEmpty)
  }

  @MainActor func testRestorationAndAppearanceWritesStayInTheirOwnDataRoot() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let firstRoot = root.appendingPathComponent("first")
    let secondRoot = root.appendingPathComponent("second")
    var first = WorkspaceLibrary()
    first.appearance = AppearancePreferences()
    first.appearance?.codeSize = 18
    first.drafts["new:none"] = "first draft"
    try first.save(to: firstRoot.appendingPathComponent("workspace.json"))
    var second = WorkspaceLibrary()
    second.drafts["new:none"] = "second draft"
    try second.save(to: secondRoot.appendingPathComponent("workspace.json"))
    let a = WorkspaceStore(dataRoot: firstRoot)
    let b = WorkspaceStore(dataRoot: secondRoot)
    await a.restore()
    await b.restore()
    XCTAssertEqual(a.appearance.codeSize, 18)
    XCTAssertEqual(b.appearance.codeSize, 12)
    XCTAssertEqual(a.draft, "first draft")
    XCTAssertEqual(b.draft, "second draft")
    a.appearance = AppearancePreferences()
    let saved = try WorkspaceLibrary.load(from: secondRoot.appendingPathComponent("workspace.json"))
    XCTAssertEqual(saved.drafts["new:none"], "second draft")
    XCTAssertEqual(b.draft, "second draft")
    XCTAssertNil(a.project)
    XCTAssertNil(b.project)
  }
}
