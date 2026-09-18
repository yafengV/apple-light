import AppKit
import XCTest

@testable import ShipiOS

final class AppearanceTests: XCTestCase {
  func testOldLibraryAndThemePersistence() throws {
    var library = try JSONDecoder().decode(WorkspaceLibrary.self, from: Data("{}".utf8))
    XCTAssertNil(library.appearance)
    var theme = AppearancePreferences()
    theme.theme = "dark"
    theme.uiFont = "Helvetica"
    theme.codeFont = "Menlo"
    theme.uiSize = 15
    theme.codeSize = 16
    theme.accent = "#88BBEE"
    library.appearance = theme
    let loaded = try JSONDecoder().decode(
      WorkspaceLibrary.self, from: JSONEncoder().encode(library))
    XCTAssertEqual(loaded.appearance, theme)
  }

  func testInvalidSizesAndColorsNormalizeToUsableValues() {
    var value = AppearancePreferences()
    value.theme = "future"
    value.uiSize = .infinity
    value.codeSize = -100
    value.accent = "aabbcc"
    value.foreground = "#GG0000"
    value.background = "#1234"
    value.light.contrast = 500
    value.light.accent = "not-a-color"
    value.dark.contrast = .nan
    value = value.normalized()
    XCTAssertEqual(value.theme, "system")
    XCTAssertEqual(value.uiSize, 13)
    XCTAssertEqual(value.codeSize, 10)
    XCTAssertEqual(value.accent, "#AABBCC")
    XCTAssertNil(value.foreground)
    XCTAssertNil(value.background)
    XCTAssertEqual(value.light.contrast, 100)
    XCTAssertNil(value.light.accent)
    XCTAssertEqual(value.dark.contrast, 50)
    value.uiSize = 100
    value.codeSize = .nan
    XCTAssertEqual(value.normalized().uiSize, 20)
    XCTAssertEqual(value.normalized().codeSize, 12)
  }

  func testLegacySinglePaletteMigratesToLightAndDarkThemes() throws {
    let legacy = Data(
      ##"{"theme":"dark","uiFont":"","codeFont":"","uiSize":13,"codeSize":12,"accent":"#123ABC","background":"#111111","foreground":"#EEEEEE"}"##.utf8)
    let appearance = try JSONDecoder().decode(AppearancePreferences.self, from: legacy)
    XCTAssertEqual(appearance.light.accent, "#123ABC")
    XCTAssertEqual(appearance.dark.accent, "#123ABC")
    XCTAssertEqual(appearance.light.background, "#111111")
    XCTAssertEqual(appearance.dark.foreground, "#EEEEEE")
    XCTAssertEqual(appearance.light.contrast, 45)
    XCTAssertEqual(appearance.dark.contrast, 60)
    XCTAssertFalse(appearance.usePointerCursors)
    XCTAssertEqual(appearance.diffMarkerStyle, .color)
    XCTAssertEqual(appearance.reduceMotion, .system)
  }

  func testDiffMarkersAndReducedMotionPersistAndResolve() throws {
    var appearance = AppearancePreferences()
    appearance.diffMarkerStyle = .symbols
    appearance.reduceMotion = .on
    let restored = try JSONDecoder().decode(
      AppearancePreferences.self, from: JSONEncoder().encode(appearance))
    XCTAssertEqual(restored.diffMarkerStyle, .symbols)
    XCTAssertEqual(restored.reduceMotion, .on)
    XCTAssertTrue(restored.reduceMotion.resolved(systemValue: false))
    XCTAssertFalse(ReduceMotionPreference.off.resolved(systemValue: true))
    XCTAssertTrue(ReduceMotionPreference.system.resolved(systemValue: true))
  }

  func testReviewLineTextUsesSelectedDiffMarkerStyle() throws {
    let diff = ReviewDiff("@@ -1,1 +1,1 @@\n-old\n+new\n")
    let deletion = try XCTUnwrap(diff.lines.first { $0.kind == .deletion })
    let addition = try XCTUnwrap(diff.lines.first { $0.kind == .addition })
    XCTAssertEqual(deletion.displayText(markerStyle: .symbols), "-old")
    XCTAssertEqual(addition.displayText(markerStyle: .symbols), "+new")
    XCTAssertEqual(deletion.displayText(markerStyle: .color), "old")
    XCTAssertEqual(addition.displayText(markerStyle: .color), "new")
  }

  func testThemeSharingRoundTripRejectsUnknownFormatsAndOversizedFiles() throws {
    var theme = AppearancePreferences()
    theme.codeFont = "Menlo"
    theme.background = "#123456"
    let data = try JSONEncoder().encode(AppearanceThemeFile(appearance: theme))
    XCTAssertEqual(try AppearanceThemeFile.decode(data), theme)
    let text = String(decoding: data, as: UTF8.self)
    for invalid in [
      text.replacingOccurrences(of: "shipios-theme", with: "unknown"),
      text.replacingOccurrences(of: "\"version\":1", with: "\"version\":2"),
      text.replacingOccurrences(of: "\"version\":1", with: "\"version\":true"),
    ] {
      XCTAssertThrowsError(try AppearanceThemeFile.decode(Data(invalid.utf8)))
    }
    XCTAssertThrowsError(try AppearanceThemeFile.decode(Data(repeating: 32, count: 65_537)))
    XCTAssertFalse(text.contains("projects"))
    XCTAssertFalse(text.contains("chatRuns"))
  }

  @MainActor func testNativeFontsShareFamilyAndRespectUIAndCodeSizes() throws {
    var theme = AppearancePreferences()
    theme.codeFont = "Menlo"
    theme.uiFont = "Helvetica"
    theme.codeSize = 17
    theme.uiSize = 16
    let terminal = theme.nativeFont(size: 12, code: true)
    let review = theme.nativeFont(size: 11, code: true)
    XCTAssertEqual(terminal.familyName, "Menlo")
    XCTAssertEqual(review.familyName, terminal.familyName)
    XCTAssertEqual(terminal.pointSize, 17)
    XCTAssertEqual(review.pointSize, 16)
    XCTAssertEqual(theme.nativeFont(size: 13).familyName, "Helvetica")
    XCTAssertEqual(theme.nativeFont(size: 13).pointSize, 16)
    theme.codeFont = "ShipiOS-Missing-Font-For-Test"
    XCTAssertEqual(theme.nativeFont(size: 12, code: true).pointSize, 17)
    XCTAssertNotEqual(theme.nativeFont(size: 12, code: true).familyName, theme.codeFont)
  }

  @MainActor func testColorConversionAndStoreResetDoNotModifyOtherPreferences() throws {
    XCTAssertEqual(
      AppearancePreferences.hex(try XCTUnwrap(AppearancePreferences.color("#123ABC"))), "#123ABC")
    let store = WorkspaceStore()
    store.library.preferredEditor = "xcode"
    store.library.drafts["qa"] = "保留草稿"
    var theme = AppearancePreferences()
    theme.codeSize = 16
    store.appearance = theme
    XCTAssertEqual(store.appearance.codeSize, 16)
    var callbacks = 0
    store.appearanceHandler = { _ in callbacks += 1 }
    theme.usePointerCursors = true
    store.appearance = theme
    XCTAssertEqual(callbacks, 1)
    store.appearance = AppearancePreferences()
    XCTAssertEqual(store.library.preferredEditor, "xcode")
    XCTAssertEqual(store.library.drafts["qa"], "保留草稿")
    XCTAssertEqual(callbacks, 2)
  }
}
