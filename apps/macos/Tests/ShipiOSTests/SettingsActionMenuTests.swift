import AppKit
import Observation
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class SettingsActionMenuTests: XCTestCase {
  func testDisabledFocusedMenuRejectsActionsImmediatelyAndDoesNotReplayStaleCellUpdates() async throws {
    let state = ActionMenuState()
    let (window, host) = makeHost(ActionMenuFixture(state: state))
    defer { window.close() }
    try await settle(host)
    let button = try XCTUnwrap(findControl(host))
    window.makeFirstResponder(button)
    button.isEnabled = false
    XCTAssertFalse(button.acceptsFirstResponder)
    XCTAssertFalse(button.canBecomeKeyView)
    XCTAssertFalse(button.accessibilityPerformPress())
    button.selectItem(at: 1)
    button.sendAction(button.action, to: button.target)
    XCTAssertEqual(state.actions, 0)
    // The cell cannot traverse SwiftUI's key loop inside a view transaction.
    XCTAssertTrue(button.cell?.isEnabled == true)
    try await settle(host)
    XCTAssertFalse(window.firstResponder === button)
    XCTAssertFalse(button.cell?.isEnabled == true)

    button.isEnabled = true
    button.isEnabled = false
    button.isEnabled = true
    try await settle(host)
    XCTAssertTrue(button.isEnabled)
    XCTAssertTrue(button.cell?.isEnabled == true)
    XCTAssertEqual(state.actions, 0)

    let next = NSTextField(frame: .init(x: 0, y: 0, width: 100, height: 24))
    host.addSubview(next)
    window.makeFirstResponder(button)
    button.isEnabled = false
    window.makeFirstResponder(next)
    try await settle(host)
    XCTAssertTrue(window.firstResponder === next.currentEditor(),
      "A delayed disable must not clear focus already moved by navigation")
    XCTAssertFalse(button.cell?.isEnabled == true)
  }

  func testFocusRequestTargetsNativeControlOnlyOnceAndDoesNotInvokeAction() async throws {
    let state = ActionMenuState()
    let (window, host) = makeHost(ActionMenuFixture(state: state))
    defer { window.close() }
    try await settle(host)
    let button = try XCTUnwrap(findControl(host))
    XCTAssertEqual(button.accessibilityLabel(), "项目操作")
    XCTAssertEqual(button.numberOfItems, 2)
    XCTAssertTrue(button.pullsDown)
    state.request = UUID()
    try await settle(host)
    XCTAssertTrue(window.firstResponder === button)
    XCTAssertEqual(state.actions, 0)
    window.makeFirstResponder(nil)
    state.title = "更新后的项目操作"
    try await settle(host)
    XCTAssertFalse(window.firstResponder === button, "An unrelated render must not replay a focus request")
    XCTAssertEqual(button.accessibilityLabel(), state.title)
    state.request = UUID()
    try await settle(host)
    XCTAssertTrue(window.firstResponder === button)
    XCTAssertEqual(state.actions, 0)
  }

  func testActionRequiresSelectedCommandAndLiveEnabledVisibleControl() async throws {
    let state = ActionMenuState()
    let (window, host) = makeHost(ActionMenuFixture(state: state))
    defer { window.close() }
    try await settle(host)
    let button = try XCTUnwrap(findControl(host))
    button.selectItem(at: 0)
    button.sendAction(button.action, to: button.target)
    XCTAssertEqual(state.actions, 0)
    button.selectItem(at: 1)
    button.sendAction(button.action, to: button.target)
    XCTAssertEqual(state.actions, 1)
    state.enabled = false
    state.request = UUID()
    try await settle(host)
    XCTAssertFalse(button.acceptsFirstResponder)
    button.sendAction(button.action, to: button.target)
    XCTAssertEqual(state.actions, 1)
    state.enabled = true
    try await settle(host)
    XCTAssertFalse(window.firstResponder === button, "Disabled requests must not take effect on re-enable")
    host.isHidden = true
    button.sendAction(button.action, to: button.target)
    XCTAssertEqual(state.actions, 1)
    host.isHidden = false
    state.mounted = false
    try await settle(host)
    XCTAssertFalse(button.active)
    XCTAssertNil(button.target)
  }

  func testPendingRestorationIsInvalidatedByDisableOrTeardown() async throws {
    let (window, host) = makeHost(Text("host"))
    defer { window.close() }
    let button = SettingsMenuControl(frame: .zero, pullsDown: true)
    host.addSubview(button)
    let coordinator = SettingsActionMenu.Coordinator()
    let request = UUID()
    coordinator.update(button, enabled: true, request: request, action: {})
    coordinator.update(button, enabled: false, request: request, action: {})
    coordinator.update(button, enabled: true, request: request, action: {})
    try await settle(host)
    XCTAssertFalse(window.firstResponder === button)
    coordinator.update(button, enabled: true, request: UUID(), action: {})
    coordinator.stop()
    try await settle(host)
    XCTAssertFalse(window.firstResponder === button)
  }

  func testArchiveCancelReturnsToProjectMenuAndRemovedProjectFallsBackToSearch() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.openSettings(.archived)
    store.library.tasks = [.init(id: "test", project: "/project", title: "test", runIDs: [], archived: true)]
    let (window, host) = makeHost(ArchiveActionMenuFixture(store: store))
    defer { window.close() }
    try await settle(host)
    let button = try XCTUnwrap(findControl(host))
    button.selectItem(at: 1)
    button.sendAction(button.action, to: button.target)
    try await settle(host)
    XCTAssertEqual(store.archiveDeletion?.kind, .project)
    XCTAssertFalse(button.isEnabled)
    store.dismissArchiveDeletion()
    try await settle(host)
    XCTAssertTrue(window.firstResponder === button)
    button.selectItem(at: 1)
    button.sendAction(button.action, to: button.target)
    try await settle(host)
    let previous = store.settingsSearchFocusRequest
    store.library.tasks = []
    store.dismissArchiveDeletion()
    try await settle(host)
    XCTAssertNotEqual(store.settingsSearchFocusRequest, previous)
    XCTAssertFalse(button.active)
  }

  func testProjectDeletionMenuHasDangerPresentationAndBusyDisablesItsAction() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.openSettings(.archived)
    store.library.tasks = [.init(id: "test", project: "/project", title: "test", runIDs: [], archived: true)]
    let (window, host) = makeHost(ArchiveActionMenuFixture(store: store))
    defer { window.close() }
    try await settle(host)
    let button = try XCTUnwrap(findControl(host))
    let item = try XCTUnwrap(button.item(at: 1))
    XCTAssertEqual(item.attributedTitle?.string, "删除项目中的全部任务")
    XCTAssertEqual(item.attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .systemRed)
    XCTAssertNotNil(item.image)
    store.restoringArchivedTaskIDs = ["test"]
    try await settle(host)
    XCTAssertFalse(button.isEnabled)
    XCTAssertFalse(button.canBecomeKeyView)
    button.selectItem(at: 1)
    button.sendAction(button.action, to: button.target)
    XCTAssertNil(store.archiveDeletion)
    store.restoringArchivedTaskIDs = []
    try await settle(host)
    XCTAssertTrue(button.isEnabled)
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

  private func findControl(_ view: NSView) -> SettingsMenuControl? {
    if let button = view as? SettingsMenuControl { return button }
    return view.subviews.lazy.compactMap(findControl).first
  }
}

@Observable private final class ActionMenuState {
  var title = "项目操作"
  var request: UUID?
  var enabled = true
  var mounted = true
  var actions = 0
}

private struct ActionMenuFixture: View {
  let state: ActionMenuState
  var body: some View {
    if state.mounted {
      SettingsActionMenu(title: state.title, actionTitle: "删除项目中的全部任务", focusRequest: state.request) {
        state.actions += 1
      }.frame(width: 24, height: 24).disabled(!state.enabled)
    }
  }
}

private struct ArchiveActionMenuFixture: View {
  let store: WorkspaceStore
  var body: some View {
    ArchivedTasksSettingsView(store: store).disabled(store.archiveDeletion != nil)
  }
}
