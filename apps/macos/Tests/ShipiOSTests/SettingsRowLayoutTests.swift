import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

struct SettingsRowLayoutReference: Decodable {
  struct Expected: Decodable {
    let labelFontSize, descriptionFontSize, labelDescriptionGap: CGFloat
    let controlMinimum, controlWidthFraction, rowGap, labelLineHeight, descriptionLineHeight: CGFloat
  }
  struct Width: Decodable { let width, minimumControlWidth: CGFloat }
  let expected: Expected
  let widths: [Width]
  static func load() throws -> Self {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "settings_row_layout_reference_666",
      withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
  }
}

@MainActor final class SettingsRowLayoutTests: XCTestCase {
  func testTrailingControlReservationMatchesPublicCSSAtThreeWidthsAndBothDirections() async throws {
    _ = NSApplication.shared
    let reference = try SettingsRowLayoutReference.load()
    XCTAssertEqual(SettingsRowTypography.labelSize, reference.expected.labelFontSize)
    XCTAssertEqual(SettingsRowTypography.descriptionSize, reference.expected.descriptionFontSize)
    XCTAssertEqual(SettingsRowTypography.labelDescriptionGap, reference.expected.labelDescriptionGap)
    XCTAssertEqual(SettingsRowTypography.labelLineHeight, reference.expected.labelLineHeight, accuracy: 1e-10)
    XCTAssertEqual(SettingsRowTypography.descriptionLineHeight, reference.expected.descriptionLineHeight)
    for rtl in [false, true] {
      let label = NSView(), control = NSView()
      let window = makeWindow(); defer { window.close() }
      let host = NSHostingView(rootView: SettingsLabeledRow {
        RowLayoutProbe(view: label).frame(maxWidth: .infinity).frame(height: 30)
      } control: { RowLayoutProbe(view: control).frame(width: 32, height: 20) }
        .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
      window.contentView = host
      for item in reference.widths {
        window.setContentSize(.init(width: item.width, height: 300))
        host.frame.size = .init(width: item.width, height: 300)
        try await settle(host)
        let labelRect = label.convert(label.bounds, to: host)
        let controlRect = control.convert(control.bounds, to: host)
        XCTAssertEqual(labelRect.width, item.width - item.minimumControlWidth - reference.expected.rowGap, accuracy: 1)
        XCTAssertEqual(controlRect.width, 32, accuracy: 1, "Reserved area must not stretch the switch itself")
        XCTAssertEqual(controlRect.midY, labelRect.midY, accuracy: 1)
        if rtl {
          XCTAssertEqual(controlRect.minX, 0, accuracy: 1)
          XCTAssertEqual(labelRect.maxX, item.width, accuracy: 1)
        } else {
          XCTAssertEqual(labelRect.minX, 0, accuracy: 1)
          XCTAssertEqual(controlRect.maxX, item.width, accuracy: 1)
        }
      }
      XCTAssertFalse(window.isVisible)
    }
  }

  func testWideControlsRetainNaturalWidthWhileLabelsWrapAndNativeFocusSurvivesResize() async throws {
    _ = NSApplication.shared
    let reference = try SettingsRowLayoutReference.load().expected
    let label = NSView(), control = NSTextField(string: "编辑内容")
    let window = makeWindow(); defer { window.close() }
    let host = NSHostingView(rootView: SettingsLabeledRow {
      RowLayoutProbe(view: label).frame(maxWidth: .infinity).frame(height: 30)
    } control: { RowLayoutProbe(view: control).frame(width: 240, height: 30) }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
    window.contentView = host; try await settle(host)
    XCTAssertTrue(window.makeFirstResponder(control))
    let editor = try XCTUnwrap(control.currentEditor() as? NSTextView)
    editor.string = "未提交文本"; control.stringValue = editor.string
    editor.setSelectedRange(.init(location: 1, length: 2))
    for width in [CGFloat(628), 328, 500] {
      window.setContentSize(.init(width: width, height: 300)); host.frame.size = .init(width: width, height: 300)
      try await settle(host)
      let labelRect = label.convert(label.bounds, to: host)
      let controlRect = control.convert(control.bounds, to: host)
      XCTAssertEqual(controlRect.width, 240, accuracy: 1)
      XCTAssertEqual(controlRect.maxX, width, accuracy: 1)
      XCTAssertEqual(controlRect.minX - labelRect.maxX, reference.rowGap, accuracy: 1)
      XCTAssertTrue(window.firstResponder === editor)
      XCTAssertEqual(editor.string, "未提交文本")
      XCTAssertEqual(editor.selectedRange(), .init(location: 1, length: 2))
    }
  }

  func testDescriptionReflowsAtReservedControlBoundaryWithoutTruncation() async throws {
    _ = NSApplication.shared
    let window = makeWindow(); defer { window.close() }
    let probe = NSView()
    let host = NSHostingView(rootView: SettingsLabeledRow {
      SettingsControlLabel(title: "说明文字", description: String(repeating: "独立设置说明与中文换行 ", count: 8))
        .background(RowLayoutProbe(view: probe))
    } control: { Color.clear.frame(width: 32, height: 20) }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
    window.contentView = host
    var heights: [CGFloat] = []
    for width in [CGFloat(628), 328] {
      window.setContentSize(.init(width: width, height: 400)); host.frame.size = .init(width: width, height: 400)
      try await settle(host)
      heights.append(probe.bounds.height)
    }
    XCTAssertGreaterThan(heights[1], heights[0] + 20)
    XCTAssertGreaterThan(heights[0], 20)
  }

  func testSingleLineLabelAndDescriptionUsePublicLineHeightsWithoutExtraRowPadding() async throws {
    let reference = try SettingsRowLayoutReference.load().expected
    for family in ["", "Menlo", "Times New Roman"] {
      var appearance = AppearancePreferences(); appearance.uiFont = family
      let host = NSHostingView(rootView: SettingsControlLabel(title: "标题", description: "说明")
        .frame(width: 300).environment(\.appAppearance, appearance))
      try await settle(host)
      XCTAssertEqual(host.fittingSize.height,
        reference.labelLineHeight + reference.descriptionLineHeight + reference.labelDescriptionGap, accuracy: 1, family)
    }
  }

  private func makeWindow() -> NSWindow {
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 628, height: 300),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; return window
  }
  private func settle(_ host: NSView) async throws {
    try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
  }
}

private struct RowLayoutProbe: NSViewRepresentable {
  let view: NSView
  func makeNSView(context: Context) -> NSView { view }
  func updateNSView(_ nsView: NSView, context: Context) {}
}
