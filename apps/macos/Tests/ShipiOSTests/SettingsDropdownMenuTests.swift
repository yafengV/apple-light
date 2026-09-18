import AppKit
import Observation
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class SettingsDropdownMenuTests: XCTestCase {
  func testSectionsAndDuplicateLabelsKeepIndependentSelectionAndStableValues() async throws {
    let state = DropdownState()
    let (window, host) = makeHost(DropdownFixture(state: state))
    defer { window.close() }
    try await settle(host)
    let button = try XCTUnwrap(controls(host).first)
    XCTAssertEqual(button.accessibilityLabel(), "测试筛选")
    XCTAssertEqual(button.menu?.items.map(\.title), ["选择", "类型", "同名", "同名", "", "排序依据", "名称", "不可用"])
    XCTAssertEqual(button.menu?.items.filter { $0.state == .on }.map(\.title), ["同名", "名称"])
    XCTAssertTrue(button.menu?.items.allSatisfy { $0.submenu == nil } == true)
    XCTAssertEqual(button.item(at: 3)?.toolTip, "/second")
    XCTAssertNotNil(button.item(at: 3)?.image)
    button.selectItem(at: 1)
    button.sendAction(button.action, to: button.target)
    XCTAssertEqual(state.selections, [])
    button.selectItem(at: 3)
    button.sendAction(button.action, to: button.target)
    XCTAssertEqual(state.selections, [2], "Duplicate visible labels must use their own value")
    button.selectItem(at: 7)
    button.sendAction(button.action, to: button.target)
    XCTAssertEqual(state.selections, [2])
    state.items = [.option(.init(value: 9, title: "更新后的选项", selected: true))]
    try await settle(host)
    XCTAssertEqual(state.selections, [2], "External option updates must not invoke selection")
    button.selectItem(at: 1)
    button.sendAction(button.action, to: button.target)
    XCTAssertEqual(state.selections, [2, 9])
  }

  func testDisabledHiddenEmptyAndUnmountedMenusCannotAct() async throws {
    let state = DropdownState()
    let (window, host) = makeHost(DropdownFixture(state: state))
    defer { window.close() }
    try await settle(host)
    let button = try XCTUnwrap(controls(host).first)
    state.enabled = false
    try await settle(host)
    XCTAssertFalse(button.canBecomeKeyView)
    button.selectItem(at: 3)
    button.sendAction(button.action, to: button.target)
    XCTAssertTrue(state.selections.isEmpty)
    state.enabled = true
    try await settle(host)
    host.isHidden = true
    button.sendAction(button.action, to: button.target)
    XCTAssertFalse(button.acceptsFirstResponder)
    XCTAssertTrue(state.selections.isEmpty)
    host.isHidden = false
    state.items = [.section("无可用项")]
    try await settle(host)
    XCTAssertFalse(button.isEnabled)
    state.mounted = false
    try await settle(host)
    XCTAssertFalse(button.active)
    XCTAssertNil(button.target)
  }

  func testArchiveMenusKeepSortTypeAndProjectIndependentAndHandleRemovedProject() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.openSettings(.archived)
    store.library.projectNames = ["/a": "同名项目", "/b": "同名项目"]
    store.library.tasks = [
      .init(id: "a", project: "/a", title: "Alpha", runIDs: [], archived: true),
      .init(id: "b", project: "/b", title: "Beta", runIDs: [], archived: true)]
    let (window, host) = makeHost(ArchivedTasksSettingsView(store: store))
    defer { window.close() }
    try await settle(host)
    func menu(_ name: String) throws -> SettingsMenuControl {
      try XCTUnwrap(controls(host).first { $0.accessibilityLabel() == name })
    }
    let filter = try menu("筛选归档任务")
    let project = try menu("按项目筛选归档任务")
    func choose(_ button: SettingsMenuControl, _ predicate: (NSMenuItem) -> Bool) throws {
      let item = try XCTUnwrap(button.menu?.items.first(where: predicate))
      button.select(item)
      button.sendAction(button.action, to: button.target)
    }
    try choose(filter) { $0.title == "创建时间" }
    try await settle(host)
    XCTAssertEqual(filter.menu?.items.filter { $0.state == .on }.map(\.title), ["全部任务", "创建时间"])
    try choose(project) { $0.toolTip == "/b" }
    try await settle(host)
    XCTAssertEqual(project.menu?.items.filter { $0.state == .on }.map(\.toolTip), ["/b"])
    XCTAssertEqual(project.item(at: 0)?.title, "同名项目")
    try choose(filter) { $0.title == "云端" }
    try await settle(host)
    XCTAssertEqual(filter.menu?.items.filter { $0.state == .on }.map(\.title), ["云端", "创建时间"])
    XCTAssertEqual(project.menu?.items.filter { $0.state == .on }.map(\.toolTip), ["/b"])
    store.library.tasks.removeAll { $0.project == "/b" }
    try await settle(host)
    XCTAssertEqual(project.menu?.items.filter { $0.state == .on }.map(\.title), ["所有项目"])
    XCTAssertEqual(project.item(at: 0)?.title, "所有项目")
    XCTAssertEqual(filter.menu?.items.filter { $0.state == .on }.map(\.title), ["云端", "创建时间"])
  }

  private func makeHost<Content: View>(_ content: Content) -> (NSWindow, NSHostingView<Content>) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 600),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: content)
    window.contentView = host
    return (window, host)
  }
  private func settle(_ host: NSView) async throws {
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
  }
  private func controls(_ view: NSView) -> [SettingsMenuControl] {
    (view as? SettingsMenuControl).map { [$0] } ?? view.subviews.flatMap(controls)
  }
}

@Observable private final class DropdownState {
  var enabled = true
  var mounted = true
  var selections: [Int] = []
  var items: [SettingsDropdownItem<Int>] = [
    .section("类型"), .option(.init(value: 1, title: "同名", selected: true)),
    .option(.init(value: 2, title: "同名", systemImage: "folder", help: "/second")),
    .separator, .section("排序依据"), .option(.init(value: 3, title: "名称", selected: true)),
    .option(.init(value: 4, title: "不可用", enabled: false))]
}

private struct DropdownFixture: View {
  let state: DropdownState
  var body: some View {
    if state.mounted {
      SettingsDropdownMenu(title: "选择", accessibilityLabel: "测试筛选", systemImage: "folder",
        items: state.items) { state.selections.append($0) }
        .frame(width: 176, height: 24).disabled(!state.enabled)
    }
  }
}
