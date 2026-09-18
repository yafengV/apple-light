import XCTest

@testable import ShipiOS

final class SidebarOrganizationTests: XCTestCase {
  private func fixture() -> WorkspaceLibrary {
    var library = WorkspaceLibrary()
    library.projects = ["/app", "/docs"]
    library.tasks = [
      WorkspaceTask(id: "one", project: "/app", title: "One", runIDs: ["r1"]),
      WorkspaceTask(id: "two", project: "/app", title: "Two", runIDs: ["r2"]),
      WorkspaceTask(id: "three", project: "/docs", title: "Three", runIDs: ["r3"]),
    ]
    library.sidebar.groups = [
      SidebarGroup(id: "release", name: "Release"), SidebarGroup(id: "later", name: "Later"),
    ]
    return library
  }

  func testMovingTaskChangesOnlyPresentationAndPreventsCrossProjectReparenting() {
    var library = fixture()
    library.drafts["one"] = "unsent"
    XCTAssertTrue(library.moveSidebarItem(.task("one"), to: "release"))
    XCTAssertEqual(library.sidebarItems(in: "release"), [.task("one")])
    XCTAssertEqual(library.sidebarItems(in: SidebarLayout.project("/app")), [.task("two")])
    XCTAssertEqual(library.tasks[0].project, "/app")
    XCTAssertEqual(library.tasks[0].runIDs, ["r1"])
    XCTAssertEqual(library.drafts["one"], "unsent")
    let layout = library.sidebar
    XCTAssertFalse(library.moveSidebarItem(.task("one"), to: SidebarLayout.project("/docs")))
    XCTAssertEqual(library.sidebar, layout)
  }

  func testPinsAndGroupsAreMutuallyExclusiveForProjectsAndTasks() {
    var library = fixture()
    for item in [SidebarItem.task("one"), .project("/docs")] {
      XCTAssertTrue(library.moveSidebarItem(item, to: SidebarLayout.pinned))
      XCTAssertEqual(library.sidebarSection(for: item), SidebarLayout.pinned)
      XCTAssertTrue(library.moveSidebarItem(item, to: "release"))
      XCTAssertEqual(library.sidebarSection(for: item), "release")
      XCTAssertFalse(library.sidebarItems(in: SidebarLayout.pinned).contains(item))
    }
    XCTAssertFalse(library.tasks[0].pinned)
    XCTAssertFalse(library.pinnedProjects.contains("/docs"))
    library.moveSidebarItem(.task("one"), to: SidebarLayout.pinned)
    XCTAssertNil(library.sidebar.placement["t:one"])
    XCTAssertTrue(library.tasks[0].pinned)
  }

  func testMixedOrderingPersistsAndSurvivesProjectVisitsAndTaskUpdates() throws {
    var library = fixture()
    library.moveSidebarItem(.project("/docs"), to: "release")
    library.moveSidebarItem(.task("one"), to: "release", before: .project("/docs"))
    library.moveSidebarItem(.task("two"), to: "release", before: .task("one"))
    library.visit("/app")
    let decoded = try JSONDecoder().decode(
      WorkspaceLibrary.self, from: JSONEncoder().encode(library))
    XCTAssertEqual(
      decoded.sidebarItems(in: "release"), [.task("two"), .task("one"), .project("/docs")])
    XCTAssertEqual(decoded.orderedProjects, ["/docs", "/app"])
    XCTAssertEqual(decoded.tasks.count, 3)
  }

  func testDeleteGroupRestoresMembersIncludingArchivedTasksWithoutDeletingHistory() {
    var library = fixture()
    library.moveSidebarItem(.project("/docs"), to: "release")
    library.moveSidebarItem(.task("one"), to: "release")
    library.tasks[0].archived = true
    library.deleteSidebarGroup("release")
    XCTAssertEqual(library.projects.count, 2)
    XCTAssertEqual(library.tasks.count, 3)
    XCTAssertEqual(library.sidebarSection(for: .task("one")), SidebarLayout.project("/app"))
    XCTAssertEqual(library.sidebarSection(for: .project("/docs")), SidebarLayout.projects)
    XCTAssertTrue(library.tasks[0].archived)
    library.tasks[0].archived = false
    XCTAssertTrue(library.sidebarItems(in: SidebarLayout.project("/app")).contains(.task("one")))
    XCTAssertNil(library.sidebar.order["release"])
  }

  func testInvalidDropHasNoEffectAndGroupOrderIsIndependent() {
    var library = fixture()
    let before = library.sidebar
    XCTAssertFalse(library.moveSidebarItem(.project("/unregistered"), to: "release"))
    XCTAssertFalse(library.moveSidebarItem(.task("one"), to: "missing"))
    XCTAssertFalse(library.moveSidebarItem(.project("/app"), to: "release", before: .task("two")))
    XCTAssertFalse(library.moveSidebarGroup("release", before: "missing"))
    XCTAssertEqual(library.sidebar, before)
    XCTAssertTrue(library.moveSidebarGroup("later", before: "release"))
    XCTAssertEqual(library.sidebar.groups.map(\.id), ["later", "release"])
    XCTAssertEqual(library.projects, ["/app", "/docs"])
  }

  func testLegacyPinnedItemsRemainVisibleExactlyOnce() throws {
    var library = try JSONDecoder().decode(
      WorkspaceLibrary.self,
      from: Data(
        #"{"projects":["/app","/docs"],"pinnedProjects":["/docs"],"tasks":[{"id":"one","project":"/app","title":"One","runIDs":["r1"],"pinned":true,"archived":false}]}"#
          .utf8))
    XCTAssertTrue(library.sidebar.groups.isEmpty)
    XCTAssertEqual(
      library.sidebarItems(in: SidebarLayout.pinned), [.project("/docs"), .task("one")])
    library.sidebar.order[SidebarLayout.pinned] = ["t:one", "t:one", "missing"]
    XCTAssertEqual(
      library.sidebarItems(in: SidebarLayout.pinned), [.task("one"), .project("/docs")])
  }

  func testPinnedContentReferenceStaysInPinnedSection() {
    var library = fixture()
    let pin = PinnedWorkspaceTab(
      id: "pin", sourceTabID: "review:one", owner: "one", kind: .review,
      title: "Review", restoreURL: nil)
    library.pinnedContentTabs = [pin]
    let item = SidebarItem.contentTab(pin.id)
    XCTAssertEqual(library.sidebarSection(for: item), SidebarLayout.pinned)
    XCTAssertTrue(library.sidebarItems(in: SidebarLayout.pinned).contains(item))
    XCTAssertFalse(library.moveSidebarItem(item, to: "release"))
    XCTAssertTrue(library.moveSidebarItem(item, to: SidebarLayout.pinned))
  }

  @MainActor func testMenuAndDragShareMovementAndRejectExternalText() {
    let store = WorkspaceStore()
    store.library = fixture()
    XCTAssertFalse(store.acceptSidebarDrop(["/app"], to: "release"))
    XCTAssertTrue(store.acceptSidebarDrop([SidebarItem.task("one").dragToken], to: "release"))
    store.moveSidebarItem(.task("two"), to: "release")
    store.shiftSidebarItem(.task("two"), by: -1)
    XCTAssertEqual(store.library.sidebarItems(in: "release"), [.task("two"), .task("one")])
    store.shiftSidebarItem(.task("two"), by: 1)
    XCTAssertEqual(store.library.sidebarItems(in: "release"), [.task("one"), .task("two")])
    XCTAssertTrue(store.acceptSidebarDrop(["shipios-group-v1:later"], to: "release"))
    XCTAssertEqual(store.library.sidebar.groups.map(\.id), ["later", "release"])
  }

  @MainActor func testCreateRenameCollapseAndRevealGroup() throws {
    let store = WorkspaceStore()
    store.library = fixture()
    store.project = URL(fileURLWithPath: "/app")
    store.editSidebarGroup(moving: .task("one"))
    store.sidebarGroupDraft = " New group "
    store.saveSidebarGroup(try XCTUnwrap(store.sidebarGroupEditor))
    let group = try XCTUnwrap(store.library.sidebar.groups.last)
    XCTAssertEqual(group.name, "New group")
    XCTAssertEqual(store.library.sidebarSection(for: .task("one")), group.id)
    store.editSidebarGroup(group)
    store.sidebarGroupDraft = "Renamed"
    store.saveSidebarGroup(try XCTUnwrap(store.sidebarGroupEditor))
    store.toggleSidebarGroup(group.id)
    XCTAssertTrue(store.library.sidebar.groups.last!.collapsed)
    store.selectTask(store.library.tasks[0])
    XCTAssertFalse(store.library.sidebar.groups.last!.collapsed)
    XCTAssertEqual(store.library.sidebar.groups.last!.name, "Renamed")
  }

  @MainActor func testDraggingTaskBackToOwningProjectRevealsItWithoutChangingOwnership() {
    let store = WorkspaceStore()
    store.library = fixture()
    store.moveSidebarItem(.task("one"), to: "release")
    store.library.collapsedProjects.insert("/app")
    let token = SidebarItem.task("one").dragToken
    XCTAssertFalse(store.acceptSidebarItemDrop([token], on: .project("/docs")))
    XCTAssertTrue(store.acceptSidebarItemDrop([token], on: .project("/app")))
    XCTAssertFalse(store.library.collapsedProjects.contains("/app"))
    XCTAssertTrue(
      store.library.sidebarItems(in: SidebarLayout.project("/app")).contains(.task("one")))
    XCTAssertEqual(store.library.tasks[0].project, "/app")
  }
}
