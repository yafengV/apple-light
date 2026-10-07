import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class DockIconTests: XCTestCase {
  func testPublicReferenceVisibilityRadioCallbacksAndCardGeometry() throws {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "dock_icon_reference_651", withExtension: "json", subdirectory: "Fixtures"))
    let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    XCTAssertEqual(fixture["version"] as? String, "26.930.51102")
    XCTAssertEqual(fixture["defaultPreference"] as? String, AppearancePreferences().dockIcon.rawValue)
    let hashes = try XCTUnwrap(fixture["sourceSHA256"] as? [String: String])
    XCTAssertEqual(hashes["settings"], "91ef510e7631785df4c62c25f3b9018a0ca3c15ce3fa1b208f3cf8394abdf535")
    XCTAssertEqual(hashes["visibility"], "44dcb985ac16b5c5e3d52bd8a84cc44b7122fb063159fca97fc6543931fd8de6")
    XCTAssertEqual(hashes["shared"], "eb2500c5398279d4fbf5c71d7ce982d54631660907761740199f6c22591d71ab")
    let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
    XCTAssertEqual(cases.count, 36)
    for sample in cases {
      let visible = sample["platform"] as? String == "macOS" && sample["previews"] as? Bool == true
      XCTAssertEqual(sample["visible"] as? Bool, visible)
      let options = try XCTUnwrap(sample["options"] as? [[String: Any]])
      XCTAssertEqual(options.count, visible ? (sample["spaces"] as? Bool == true ? 3 : 2) : 0)
      XCTAssertEqual(sample["writes"] as? [String], options.compactMap { $0["value"] as? String })
      for option in options {
        XCTAssertEqual(option["radioType"] as? String, "radio")
        XCTAssertEqual(option["name"] as? String, "dock-icon")
        XCTAssertTrue((option["cardClass"] as? String)?.contains("size-12") == true)
        XCTAssertEqual(option["checked"] as? Bool, option["value"] as? String == sample["selected"] as? String)
      }
      if visible, sample["spaces"] as? Bool == false {
        XCTAssertEqual(options.count, DockIconPreference.allCases.count)
        XCTAssertEqual(options.compactMap { $0["value"] as? String }, ["app-default", "codex-system"])
      }
    }
  }

  func testOldAndUnknownPreferencesRestoreDefaultAndAdaptiveRoundTrips() throws {
    let decoder = JSONDecoder()
    XCTAssertEqual(try decoder.decode(AppearancePreferences.self, from: Data("{}".utf8)).dockIcon, .appDefault)
    XCTAssertEqual(try decoder.decode(AppearancePreferences.self, from: Data(#"{"dockIcon":"future-icon","theme":"dark"}"#.utf8)).dockIcon, .appDefault)
    var value = AppearancePreferences(); value.dockIcon = .adaptive; value.theme = "light"
    XCTAssertEqual(try decoder.decode(AppearancePreferences.self, from: JSONEncoder().encode(value)), value)
    XCTAssertTrue(value.hasAdvancedChanges)
    XCTAssertEqual(value.resettingAdvanced().dockIcon, .appDefault)
    XCTAssertEqual(value.resettingAdvanced().theme, "light")
    XCTAssertFalse(value.resettingAdvanced().hasAdvancedChanges)
  }

  func testControllerChangesActualApplicationIconAndFollowsSystemOnlyForAdaptive() throws {
    _ = NSApplication.shared
    let original = NSApp.applicationIconImage; defer { NSApp.applicationIconImage = original }
    var dark = false
    let controller = DockIconController(systemDark: { dark })
    controller.start(); defer { controller.stop() }
    let base = try XCTUnwrap(NSApp.applicationIconImage.tiffRepresentation)
    dark = true; controller.refresh()
    XCTAssertEqual(NSApp.applicationIconImage.tiffRepresentation, base)
    controller.apply(.adaptive)
    let adaptiveDark = try XCTUnwrap(NSApp.applicationIconImage.tiffRepresentation)
    XCTAssertNotEqual(adaptiveDark, base)
    dark = false; controller.refresh()
    let adaptiveLight = try XCTUnwrap(NSApp.applicationIconImage.tiffRepresentation)
    XCTAssertNotEqual(adaptiveLight, adaptiveDark)
    controller.apply(.appDefault)
    XCTAssertEqual(NSApp.applicationIconImage.tiffRepresentation, base)
  }

  func testNativeSelectionSavesOnceRestoresAndDoesNotChangeInterfaceMode() async throws {
    let f = try await fixture(); defer { f.window.close() }
    var applied: [DockIconPreference] = []
    f.store.appearanceHandler = { applied.append($0.dockIcon) }
    let next = f.group.radios[1]
    XCTAssertTrue(next.accessibilityPerformPress()); try await settle(f.host)
    XCTAssertEqual(f.store.appearance.dockIcon, .adaptive)
    XCTAssertEqual(f.store.appearance.theme, "light")
    XCTAssertEqual(applied, [.adaptive])
    XCTAssertEqual(f.group.selected, .adaptive)
    XCTAssertTrue(next.accessibilityPerformPress())
    XCTAssertEqual(applied, [.adaptive], "Selecting the current radio must not save or reinstall the icon")
    let library = try WorkspaceLibrary.load(from: f.root.appendingPathComponent("workspace.json"))
    XCTAssertEqual(library.appearance?.dockIcon, .adaptive)
    XCTAssertEqual(library.drafts["fixture"], "keep")
    let restored = WorkspaceStore(dataRoot: f.root); restored.library = library; restored.libraryLoaded = true
    XCTAssertEqual(restored.appearance.dockIcon, .adaptive)
    XCTAssertFalse(f.window.isVisible)
  }

  func testActualAppKitAppearanceObservationUpdatesAdaptiveIconAndStops() async throws {
    _ = NSApplication.shared
    let original = NSApp.appearance; defer { NSApp.appearance = original }
    NSApp.appearance = NSAppearance(named: .aqua)
    var images: [Data] = []
    let controller = DockIconController(install: { if let data = $0.tiffRepresentation { images.append(data) } })
    controller.apply(.adaptive); controller.start(); defer { controller.stop() }
    XCTAssertEqual(images.count, 1)
    NSApp.appearance = NSAppearance(named: .darkAqua)
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while images.count < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(images.count, 2, "An actual AppKit appearance change must reach the installed observation")
    if images.count == 2 { XCTAssertNotEqual(images[0], images[1]) }
    controller.stop(); NSApp.appearance = NSAppearance(named: .aqua)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(images.count, 2)
  }

  func testQueuedAppearanceNotificationCannotReinstallAfterStopOrNewObservation() async throws {
    _ = NSApplication.shared
    let original = NSApp.appearance; defer { NSApp.appearance = original }
    NSApp.appearance = NSAppearance(named: .aqua)
    var installs = 0
    let controller = DockIconController(install: { _ in installs += 1 })
    controller.apply(.adaptive); controller.start()
    XCTAssertEqual(installs, 1)
    NSApp.appearance = NSAppearance(named: .darkAqua)
    controller.stop()
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(installs, 1, "The queued old observer must not install after teardown")
    controller.start(); defer { controller.stop() }
    XCTAssertEqual(installs, 2)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(installs, 2)
  }

  func testSaveFailureRetainsOldSelectionAndDoesNotInstallThenRetrySucceeds() async throws {
    let f = try await fixture(); defer { f.window.close() }
    var applied: [DockIconPreference] = []
    f.store.appearanceHandler = { applied.append($0.dockIcon) }
    let file = f.root.appendingPathComponent("workspace.json")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    XCTAssertFalse(f.group.radios[1].accessibilityPerformPress())
    XCTAssertEqual(f.group.selected, .appDefault); XCTAssertEqual(f.store.appearance.dockIcon, .appDefault)
    XCTAssertTrue(applied.isEmpty); XCTAssertNotNil(f.store.generalSettingsError)
    try FileManager.default.removeItem(at: file)
    XCTAssertTrue(f.group.radios[1].accessibilityPerformPress()); try await settle(f.host)
    XCTAssertEqual(applied, [.adaptive]); XCTAssertNil(f.store.generalSettingsError)
    XCTAssertEqual(try WorkspaceLibrary.load(from: file).appearance?.dockIcon, .adaptive)
  }

  func testRadioGeometryAccessibilitySingleTabStopAndArrowWrap() async throws {
    let f = try await fixture(); defer { f.window.close() }
    XCTAssertEqual(f.group.accessibilityRole(), .radioGroup)
    XCTAssertEqual(f.group.accessibilityLabel(), "Dock 图标")
    for radio in f.group.radios {
      XCTAssertEqual(radio.frame.size, NSSize(width: 48, height: 48))
      XCTAssertEqual(radio.accessibilityRole(), .radioButton)
      XCTAssertEqual(radio.accessibilityLabel(), radio.preference.title)
    }
    XCTAssertEqual(f.group.radios.filter(\.canBecomeKeyView).map(\.preference), [.appDefault])
    XCTAssertTrue(f.window.makeFirstResponder(f.group.radios[0]))
    f.group.radios[0].keyDown(with: try key(124, window: f.window)); try await settle(f.host)
    XCTAssertEqual(f.store.appearance.dockIcon, .adaptive)
    XCTAssertTrue(f.window.firstResponder === f.group.radios[1])
    XCTAssertEqual(f.group.radios.filter(\.canBecomeKeyView).map(\.preference), [.adaptive])
    f.group.radios[1].keyDown(with: try key(124, window: f.window)); try await settle(f.host)
    XCTAssertEqual(f.store.appearance.dockIcon, .appDefault)
    f.group.radios[0].keyDown(with: try key(123, window: f.window)); try await settle(f.host)
    XCTAssertEqual(f.store.appearance.dockIcon, .adaptive)
    XCTAssertEqual(f.group.radios[1].accessibilityValue() as? NSNumber, 1)
  }

  func testUnavailableModalAndRemovedControlCannotChangePreference() async throws {
    let f = try await fixture(); defer { f.window.close() }
    f.store.libraryLoaded = false
    XCTAssertFalse(f.group.radios[1].accessibilityPerformPress())
    f.store.libraryLoaded = true; f.store.restoringLibrary = true
    XCTAssertFalse(f.group.radios[1].accessibilityPerformPress())
    f.store.restoringLibrary = false
    let scope = Scope(root: NSView()); WindowModalInteraction.install(scope, in: f.window)
    XCTAssertFalse(f.group.radios[1].accessibilityPerformPress())
    WindowModalInteraction.remove(scope, from: f.window)
    XCTAssertTrue(f.group.radios[1].accessibilityPerformPress())
    let old = f.group.radios[0]
    f.window.contentView = NSView(); try await settle(f.host)
    XCTAssertFalse(old.accessibilityPerformPress())
    XCTAssertEqual(f.store.appearance.dockIcon, .adaptive)
  }

  func testRealAppearancePageDisclosureSearchAndResetUpdateDockPreference() async throws {
    let f = try await fixture(); defer { f.window.close() }
    let presentation = AppearancePagePresentation()
    let host = NSHostingView(rootView: AppearanceSettingsView(store: f.store, presentation: presentation))
    f.window.contentView = host; f.window.setContentSize(NSSize(width: 816, height: 2600)); try await settle(host)
    XCTAssertTrue(find(host, AppearanceDockIconPicker.Group.self).isEmpty)
    presentation.advancedExpanded = true; try await settle(host)
    let group = try XCTUnwrap(find(host, AppearanceDockIconPicker.Group.self).first,
      "Full page bounds: \(host.bounds); advanced: \(presentation.advancedExpanded); font inputs: \(find(host, AppearanceFontSizeInput.Control.self).count)")
    XCTAssertTrue(group.radios[1].accessibilityPerformPress()); try await settle(host)
    XCTAssertEqual(f.store.appearance.dockIcon, .adaptive)
    let reset = try XCTUnwrap(find(host, AppearanceActionButton.Control.self).first { $0.accessibilityLabel() == "重置高级外观设置" })
    XCTAssertTrue(reset.accessibilityPerformPress()); try await settle(host)
    XCTAssertEqual(f.store.appearance.dockIcon, .appDefault)
    XCTAssertEqual(group.selected, .appDefault)
    XCTAssertTrue(SettingsSearch.results(for: "程序坞").contains { $0.field == .dockIcon && $0.page == .appearance })
    f.store.revealSetting(.init(page: .appearance, field: .dockIcon))
    let searchHost = NSHostingView(rootView: AppearanceSettingsView(store: f.store))
    f.window.contentView = searchHost; try await settle(searchHost)
    XCTAssertEqual(find(searchHost, AppearanceDockIconPicker.Group.self).count, 1)
    XCTAssertEqual(f.store.library.drafts["fixture"], "keep")
  }

  private struct Fixture { let root: URL; let store: WorkspaceStore; let window: NSWindow; let host: NSView; let group: AppearanceDockIconPicker.Group }
  private func fixture() async throws -> Fixture {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("dock-icon-" + UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true; store.destination = .settings; store.settingsPage = .appearance
    store.library.drafts["fixture"] = "keep"
    var value = store.appearance; value.theme = "light"; XCTAssertTrue(store.commitAppearance(value))
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 816, height: 2600), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: AppearanceDockIconPicker(store: store).frame(width: 104, height: 48))
    window.contentView = host; try await settle(host)
    return Fixture(root: root, store: store, window: window, host: host, group: try XCTUnwrap(find(host, AppearanceDockIconPicker.Group.self).first))
  }
  private final class Scope: WindowModalScope { let modalRoot: NSView; var modalScopeActive = true; init(root: NSView) { modalRoot = root } }
  private func key(_ code: UInt16, window: NSWindow) throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
  }
  private func find<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] { (view as? T).map { [$0] } ?? view.subviews.flatMap { find($0, type) } }
  private func settle(_ view: NSView) async throws { try await Task.sleep(for: .milliseconds(160)); view.layoutSubtreeIfNeeded() }
}
