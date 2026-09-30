import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class NoticeKeyboardAndLifetimeTests: XCTestCase {
  func testTabOrderKeepsInlineAndBottomActionsInRenderedSequence() {
    let inline = WorkspaceNotice(id: "inline", title: "Inline", level: .info, taskID: "one", remaining: 5)
    let bottom = WorkspaceNotice(id: "bottom", title: "Bottom", description: "Details", level: .info,
      taskID: "two", remaining: 5)
    let pending = WorkspaceNotice(id: "pending", title: "Pending", level: .pending, remaining: nil)
    let order = NoticeTabOrder.tokens(for: [inline, bottom, pending], actionsEnabled: true)
    XCTAssertEqual(order, [inline.generation.uuidString + "-row", inline.generation.uuidString + "-view",
      inline.generation.uuidString + "-close", bottom.generation.uuidString + "-row",
      bottom.generation.uuidString + "-close", bottom.generation.uuidString + "-view",
      pending.generation.uuidString + "-row"])
    XCTAssertEqual(NoticeTabOrder.tokens(for: [inline], actionsEnabled: false),
      [inline.generation.uuidString + "-row", inline.generation.uuidString + "-close"])
  }

  func testActualToasterKeyboardCallbacksAndFocusReturn() throws {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "notice_keyboard_reference", withExtension: "json", subdirectory: "Fixtures"))
    let f = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    XCTAssertEqual(f["initialSHA256"] as? String, "01c04b2e5a96e5dd4c97e02ffa183f571a55bef7a221abd99404246c430f2212")
    XCTAssertEqual(f["sourceSHA256"] as? String, "1e9a3a8f4ec5539cb42fa61d799ce1e5b04bd642874368d402902a400171d180")
    let region = try XCTUnwrap(f["region"] as? [String: Any])
    XCTAssertEqual(region["ariaLabel"] as? String, "Notifications alt+T")
    XCTAssertEqual(region["tabIndex"] as? Int, -1)
    XCTAssertEqual(region["ariaLive"] as? String, "polite")
    let hotkey = try XCTUnwrap(f["hotkey"] as? [String: Any])
    XCTAssertEqual(hotkey["expanded"] as? [Bool], [false, true])
    XCTAssertEqual(hotkey["focused"] as? String, "toaster")
    XCTAssertEqual((hotkey["focusOptions"] as? [String: Any])?["preventScroll"] as? Bool, true)
    XCTAssertEqual((f["extraModifiers"] as? [String: Any])?["expanded"] as? Bool, true)
    XCTAssertEqual(f["escapeInside"] as? Bool, false)
    XCTAssertEqual(f["pendingDidNotCapture"] as? Bool, true)
    XCTAssertEqual(f["unmountRestoresPrior"] as? Bool, true)
    let pointer = try XCTUnwrap(f["pointer"] as? [String: Any])
    XCTAssertEqual(pointer["expanded"] as? [Bool], [true, true, false, false])
    XCTAssertEqual(pointer["interacting"] as? [Bool], [true, false])
  }

  func testNativeRegionOptionTTabEscapeReturnAndModalBoundaryWithoutShowingWindow() async throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 200),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let root = NSView(frame: .init(x: 0, y: 0, width: 300, height: 200))
    let previous = FocusableNoticeTestView(frame: .init(x: 0, y: 0, width: 80, height: 30))
    let region = NoticeKeyboardBridge.Region(frame: .zero)
    root.addSubview(previous); root.addSubview(region); window.contentView = root
    XCTAssertTrue(window.makeFirstResponder(previous))
    let state = NoticeInteractionState(notices: WorkspaceNotices())
    let coordinator = NoticeKeyboardBridge.Coordinator(interaction: state)
    coordinator.attach(region); defer { coordinator.stop() }
    var firstCount = 0
    coordinator.focusFirst = { firstCount += 1 }
    coordinator.focusedCard = { nil }
    coordinator.firstCard = { "first-row" }
    let optionT = try key(17, window: window, flags: [.option], text: "†")
    let escape = try key(53, window: window, text: "\u{1B}")
    let tab = try key(48, window: window, text: "\t")
    XCTAssertTrue(coordinator.handle(optionT)); XCTAssertTrue(state.expanded)
    XCTAssertTrue(window.firstResponder === region)
    XCTAssertFalse(coordinator.handle(escape)); XCTAssertFalse(state.expanded)
    XCTAssertTrue(window.firstResponder === region)
    XCTAssertTrue(coordinator.handle(tab)); XCTAssertEqual(firstCount, 1)
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertTrue(coordinator.handle(try key(48, window: window, flags: [.shift], text: "\t")))
    XCTAssertTrue(window.firstResponder === previous)
    XCTAssertTrue(coordinator.handle(try key(17, window: window, flags: [.option, .shift], text: "†")))
    XCTAssertTrue(window.firstResponder === region)
    coordinator.restoreIfNeeded(); XCTAssertTrue(window.firstResponder === previous)
    let scope = NoticeTestModalScope(root: previous)
    WindowModalInteraction.install(scope, in: window)
    XCTAssertFalse(coordinator.handle(optionT)); XCTAssertTrue(window.firstResponder === previous)
    WindowModalInteraction.remove(scope, from: window)
    XCTAssertFalse(window.isVisible); XCTAssertNil(window.attachedSheet)
    XCTAssertFalse(region.canBecomeKeyView); XCTAssertNil(region.hitTest(.zero))
  }

  func testReturnFocusPreservesFieldEditorSelectionInHiddenWindow() throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 150),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let root = NSView(frame: .init(x: 0, y: 0, width: 300, height: 150))
    let field = NSTextField(frame: .init(x: 10, y: 10, width: 220, height: 25))
    field.stringValue = "Original input"
    let region = NoticeKeyboardBridge.Region(frame: .zero)
    root.addSubview(field); root.addSubview(region); window.contentView = root
    XCTAssertTrue(window.makeFirstResponder(field))
    let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
    editor.setSelectedRange(.init(location: 3, length: 4))
    let interaction = NoticeInteractionState(notices: WorkspaceNotices())
    let coordinator = NoticeKeyboardBridge.Coordinator(interaction: interaction)
    coordinator.attach(region); defer { coordinator.stop() }
    coordinator.firstCard = { "first-row" }
    let hotkey = try key(17, window: window, flags: [.option], text: "†")
    XCTAssertTrue(coordinator.handle(hotkey)); XCTAssertTrue(window.firstResponder === region)
    coordinator.restoreIfNeeded()
    XCTAssertTrue(window.firstResponder === field.currentEditor())
    XCTAssertEqual((field.currentEditor() as? NSTextView)?.selectedRange(), .init(location: 3, length: 4))
    XCTAssertEqual(field.stringValue, "Original input")
    XCTAssertFalse(window.isVisible)
  }

  func testVisibilityBridgePausesHiddenWindowAndResumesOnlyRemainingTime() throws {
    _ = NSApplication.shared
    var time: TimeInterval = 100
    let notices = WorkspaceNotices(); notices.show(id: "a", title: "A", level: .info, at: time)
    let interaction = NoticeInteractionState(notices: notices, uptime: { time })
    let window = NoticeVisibilityTestWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 200),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let source = NoticeAnnouncementSource.Source()
    let coordinator = NoticeAnnouncementSource.Coordinator(interaction: interaction, announce: { _, _ in XCTFail("Hidden test must not post") })
    coordinator.attach(source); window.contentView = source
    XCTAssertTrue(interaction.documentHidden); XCTAssertTrue(notices.paused)
    time = 200; window.simulatedVisible = true; coordinator.refreshVisibility()
    XCTAssertFalse(interaction.documentHidden); XCTAssertEqual(notices.items.first?.remaining, 5)
    time = 201; interaction.tick(); XCTAssertEqual(notices.items.first?.remaining, 4)
    window.simulatedVisible = false; coordinator.refreshVisibility()
    time = 800; interaction.tick(); XCTAssertEqual(notices.items.first?.remaining, 4)
    window.simulatedVisible = true; coordinator.refreshVisibility()
    time = 804; interaction.tick(); XCTAssertTrue(notices.items.isEmpty)
    coordinator.stop(); interaction.stop()
    XCTAssertFalse(window.isKeyWindow)
  }

  func testHiddenRealNoticeStackConnectsHotkeyRegionToFirstCardFocus() async throws {
    _ = NSApplication.shared
    let store = WorkspaceStore(dataRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    store.notices.show(id: "first", title: "First notice", level: .info)
    store.notices.show(id: "second", title: "Second notice", level: .info, taskID: "task")
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 816, height: 500),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let root = NSView(frame: window.contentRect(forFrameRect: window.frame))
    let previous = FocusableNoticeTestView(frame: .init(x: 0, y: 0, width: 50, height: 24))
    let host = NSHostingView(rootView: WorkspaceNoticesView(store: store))
    host.frame = root.bounds; root.addSubview(previous); root.addSubview(host); window.contentView = root
    try await Task.sleep(for: .milliseconds(120)); host.layoutSubtreeIfNeeded()
    func find(_ view: NSView) -> NoticeKeyboardBridge.Region? {
      if let region = view as? NoticeKeyboardBridge.Region { return region }
      return view.subviews.lazy.compactMap(find).first
    }
    let region = try XCTUnwrap(find(host)), coordinator = try XCTUnwrap(region.coordinator)
    XCTAssertTrue(window.makeFirstResponder(previous))
    XCTAssertTrue(coordinator.handle(try key(17, window: window, flags: [.option], text: "†")))
    XCTAssertTrue(window.firstResponder === region)
    XCTAssertTrue(coordinator.handle(try key(48, window: window, text: "\t")))
    try await Task.sleep(for: .milliseconds(50)); host.layoutSubtreeIfNeeded()
    XCTAssertFalse(window.firstResponder === region, "Tab must actually enter the native first card")
    XCTAssertEqual(coordinator.focusedCard?(), store.notices.items.first?.generation.uuidString.appending("-row"))
    let expected = [
      store.notices.items[0].generation.uuidString + "-view",
      store.notices.items[0].generation.uuidString + "-close",
      store.notices.items[1].generation.uuidString + "-row",
      store.notices.items[1].generation.uuidString + "-close",
    ]
    for token in expected {
      let next = try key(48, window: window, text: "\t")
      XCTAssertTrue(coordinator.handle(next), "The notification region follows DOM order during motion")
      try await Task.sleep(for: .milliseconds(40)); host.layoutSubtreeIfNeeded()
      XCTAssertEqual(coordinator.focusedCard?(), token)
      XCTAssertTrue(coordinator.hasPreviousFocus, "Original focus must survive internal Tab to \(token)")
    }
    let exit = try key(48, window: window, text: "\t")
    XCTAssertTrue(coordinator.handle(exit))
    try await Task.sleep(for: .milliseconds(40)); host.layoutSubtreeIfNeeded()
    XCTAssertNil(coordinator.focusedCard?())
    XCTAssertTrue(window.firstResponder === previous)
    XCTAssertTrue(coordinator.handle(try key(17, window: window, flags: [.option], text: "†")))
    XCTAssertTrue(coordinator.handle(try key(48, window: window, text: "\t")))
    try await Task.sleep(for: .milliseconds(40)); host.layoutSubtreeIfNeeded()
    XCTAssertEqual(coordinator.focusedCard?(), store.notices.items.first?.generation.uuidString.appending("-row"))
    XCTAssertTrue(coordinator.handle(try key(48, window: window, flags: [.shift], text: "\t")))
    try await Task.sleep(for: .milliseconds(40)); host.layoutSubtreeIfNeeded()
    XCTAssertNil(coordinator.focusedCard?())
    XCTAssertTrue(window.firstResponder === previous)
    XCTAssertFalse(window.isVisible); XCTAssertNil(window.attachedSheet)
  }

  private func key(_ code: UInt16, window: NSWindow, flags: NSEvent.ModifierFlags = [], text: String) throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
      timestamp: 0, windowNumber: window.windowNumber, context: nil,
      characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
  }
}

private final class FocusableNoticeTestView: NSView { override var acceptsFirstResponder: Bool { true } }
@MainActor private final class NoticeTestModalScope: WindowModalScope {
  let modalRoot: NSView
  var modalScopeActive = true
  init(root: NSView) { modalRoot = root }
}
private final class NoticeVisibilityTestWindow: NSWindow {
  var simulatedVisible = false
  override var isVisible: Bool { simulatedVisible }
}
