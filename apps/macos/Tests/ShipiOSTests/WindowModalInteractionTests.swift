import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class WindowModalInteractionTests: XCTestCase {
  func testActualDistributionModalPointerAndFocusCallbacks() throws {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "appearance_modal_barrier_reference", withExtension: "json", subdirectory: "Fixtures"))
    let f = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    XCTAssertEqual(f["initialSHA256"] as? String, "01c04b2e5a96e5dd4c97e02ffa183f571a55bef7a221abd99404246c430f2212")
    let cases = try XCTUnwrap(f["pointerCases"] as? [[String: Any]]); XCTAssertEqual(cases.count, 6)
    for sample in cases {
      let button = try XCTUnwrap(sample["button"] as? Int), ctrl = try XCTUnwrap(sample["ctrlKey"] as? Bool)
      XCTAssertEqual(sample["prevented"] as? Bool, button == 2 || (button == 0 && ctrl))
    }
    XCTAssertEqual(f["focusOutsidePrevented"] as? Bool, true)
    XCTAssertEqual(f["toastPointerDismissed"] as? Bool, true)
    let after = try XCTUnwrap(f["pointerAfter"] as? [String: Any]), cleanup = try XCTUnwrap(f["pointerCleanup"] as? [String: Any])
    XCTAssertEqual(after["bodyPointerEvents"] as? String, "none"); XCTAssertEqual(cleanup["bodyPointerEvents"] as? String, "auto")
    XCTAssertEqual(after["disabledLayers"] as? Int, 1); XCTAssertEqual(cleanup["disabledLayers"] as? Int, 0)
    let background = try XCTUnwrap(after["background"] as? [String: Any])
    XCTAssertEqual(background["disabled"] as? Bool, false); XCTAssertEqual(background["opacity"] as? Int, 1)
    let input = try XCTUnwrap(f["inputRestore"] as? [String: Any]), button = try XCTUnwrap(f["buttonRestore"] as? [String: Any])
    XCTAssertEqual(input["focused"] as? String, "input"); XCTAssertEqual(input["selections"] as? Int, 1)
    XCTAssertEqual(input["preventScroll"] as? Bool, true); XCTAssertEqual(button["focused"] as? String, "cancel")
    XCTAssertEqual(button["selections"] as? Int, 1); XCTAssertEqual(f["remainingListeners"] as? [String], [])
    XCTAssertEqual(f["ariaProtectedNames"] as? [String], ["dialog", "live", "script"])
  }
  private final class Scope: NSView, WindowModalScope {
    var modalRoot: NSView { self }
    var modalScopeActive = true
  }
  func testReplacementWeakOwnershipDetachAndOtherWindowIsolation() throws {
    _ = NSApplication.shared
    let a = makeWindow(), b = makeWindow(); defer { a.close(); b.close() }
    let background = AppearanceActionButton.Control(), other = AppearanceActionButton.Control()
    a.contentView!.addSubview(background); b.contentView!.addSubview(other)
    weak var weakOld: Scope?; let next = Scope()
    autoreleasepool {
      var old: Scope? = Scope(); weakOld = old
      a.contentView!.addSubview(old!); let inside = AppearanceActionButton.Control(); old!.addSubview(inside)
      WindowModalInteraction.install(old!, in: a)
      XCTAssertTrue(background.isEnabled); XCTAssertFalse(background.acceptsFirstResponder)
      XCTAssertTrue(inside.acceptsFirstResponder); XCTAssertTrue(other.acceptsFirstResponder)
      a.contentView!.addSubview(next); WindowModalInteraction.install(next, in: a)
      WindowModalInteraction.remove(old!, from: a); inside.removeFromSuperview(); old!.removeFromSuperview(); old = nil
    }
    XCTAssertNil(weakOld); XCTAssertFalse(background.acceptsFirstResponder, "Old cleanup must not remove the replacement")
    next.modalScopeActive = false; XCTAssertTrue(background.acceptsFirstResponder)
    next.modalScopeActive = true; XCTAssertFalse(background.accessibilityPerformPress())
    WindowModalInteraction.remove(next, from: a); XCTAssertTrue(background.acceptsFirstResponder)
    var transient: Scope? = Scope(); WindowModalInteraction.install(transient!, in: a); transient = nil
    XCTAssertTrue(background.acceptsFirstResponder, "The window must not retain a released scope")
    XCTAssertFalse(a.isVisible); XCTAssertFalse(b.isVisible)
  }
  func testLateSearchCallbacksAndNativeFocusRemainBlockedWithoutDisablingSearch() throws {
    let window = makeWindow(); defer { window.close() }
    let scope = Scope(); window.contentView!.addSubview(scope); WindowModalInteraction.install(scope, in: window)
    var query = "original", submitted = 0
    let parent = SettingsSearchInput(query: Binding(get: { query }, set: { query = $0 }), focusRequest: UUID(),
      visible: true, onMove: { _ in }, onSubmit: { submitted += 1 })
    let owner = SettingsSearchInput.Coordinator(parent), search = SettingsSearchInput.Field()
    window.contentView!.addSubview(search); search.stringValue = "stale query"
    XCTAssertTrue(search.isEnabled); XCTAssertFalse(search.acceptsFirstResponder)
    owner.searchChanged(search); XCTAssertEqual(query, "original")
    XCTAssertFalse(owner.control(search, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
    XCTAssertEqual(submitted, 0)
    WindowModalInteraction.remove(scope, from: window)
    owner.searchChanged(search); XCTAssertEqual(query, "stale query")
    XCTAssertTrue(search.acceptsFirstResponder); XCTAssertFalse(window.isVisible)
  }
  private func makeWindow() -> NSWindow {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = NSView(frame: .init(x: 0, y: 0, width: 800, height: 500)); return window
  }
}
