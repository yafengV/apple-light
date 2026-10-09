import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class RenameDialogPresentationTests: XCTestCase {
  private struct Reference: Decodable {
    struct Metrics: Decodable {
      let width, maxViewportFraction, padding, sectionGap, headerGap: CGFloat
      let headingFont, headingLineHeight, descriptionFont, descriptionLineHeight: CGFloat
      let inputHeight, inputPadding, inputFont, buttonHeight, buttonPadding, buttonFont, buttonLineHeight: CGFloat
      let borderWidth, buttonGap, closeSize, closeInset, overlayOpacity, disabledOpacity: CGFloat
    }
    let expected: Metrics
    let focusOrder, invalidFocusOrder: [String]
    static func load() throws -> Self {
      let file = try XCTUnwrap(Bundle.module.url(forResource: "rename_dialog_reference_723", withExtension: "json", subdirectory: "Fixtures"))
      return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
    }
  }

  func testCompactNativeSurfaceAndActualHeaderMatchExtractedSpacingInNarrowAndRTLLayouts() async throws {
    let r = try Reference.load().expected
    for width: CGFloat in [800, 360] {
      for rtl in [false, true] {
        let surface = NSView(), header = NSView(), input = NSView(), footer = NSView(), close = NSView()
        let host = NSHostingView(rootView: RenameDialogSurface(availableWidth: width) {
          RenameDialogHeader(title: "重命名任务", subtitle: "使用简短、易于识别的名称")
            .background(RenameGeometryProbe(view: header))
        } input: {
          Color.clear.frame(height: r.inputHeight).background(RenameGeometryProbe(view: input))
        } footer: {
          HStack(spacing: RenameDialogMetrics.buttonGap) {
            Spacer(minLength: 0)
            Button("取消") {}.buttonStyle(RenameDialogButtonStyle(role: .outline, focused: false))
            Button("保存") {}.buttonStyle(RenameDialogButtonStyle(role: .primary, focused: false))
          }.background(RenameGeometryProbe(view: footer))
        } close: { Color.clear.background(RenameGeometryProbe(view: close)) }
          .background(RenameGeometryProbe(view: surface))
          .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight))
        host.frame.size = .init(width: width, height: 400); try await settle(host)
        func rect(_ view: NSView) -> CGRect { view.convert(view.bounds, to: host) }
        let s = rect(surface), h = rect(header), i = rect(input), f = rect(footer), c = rect(close)
        XCTAssertEqual(s.width, min(r.width, width * r.maxViewportFraction), accuracy: 1)
        XCTAssertEqual(h.minX - s.minX, r.padding, accuracy: 1)
        XCTAssertEqual(s.maxX - h.maxX, r.padding, accuracy: 1)
        XCTAssertEqual(h.height, r.headingLineHeight + r.headerGap + r.descriptionLineHeight, accuracy: 1)
        // NSHostingView's coordinates can be flipped. Compare edge separation by center.
        XCTAssertEqual(abs(i.midY - h.midY), h.height / 2 + r.sectionGap + i.height / 2, accuracy: 1)
        XCTAssertEqual(abs(f.midY - i.midY), i.height / 2 + r.sectionGap + f.height / 2, accuracy: 1)
        XCTAssertEqual(f.height, r.buttonHeight, accuracy: 1)
        XCTAssertEqual(s.height, h.height + i.height + f.height + 2 * r.sectionGap + 2 * r.padding, accuracy: 1)
        XCTAssertEqual(c.width, r.closeSize, accuracy: 1); XCTAssertEqual(c.height, r.closeSize, accuracy: 1)
        XCTAssertEqual(s.maxX - c.maxX, r.closeInset, accuracy: 1, "Close remains physically right in RTL")
        XCTAssertEqual(abs(c.midY - h.midY), abs(r.closeInset + r.closeSize / 2 - r.padding - h.height / 2), accuracy: 1)
      }
    }
  }

  func testBothNativeActionButtonsUseMediumGeometryAndPreserveTextWidth() async throws {
    let r = try Reference.load().expected
    for role in [RenameDialogButtonStyle.ColorRole.outline, .primary] {
      let label = NSView(), button = NSView()
      let host = NSHostingView(rootView: Button {} label: {
        Text("保存").background(RenameGeometryProbe(view: label))
      }.buttonStyle(RenameDialogButtonStyle(role: role, focused: false))
        .background(RenameGeometryProbe(view: button)).padding(20))
      host.frame.size = .init(width: 200, height: 100); try await settle(host)
      let l = label.convert(label.bounds, to: host), b = button.convert(button.bounds, to: host)
      XCTAssertEqual(b.height, r.buttonHeight, accuracy: 1)
      XCTAssertEqual(b.width - l.width, 2 * (r.buttonPadding + r.borderWidth), accuracy: 1)
      XCTAssertEqual(b.midX, l.midX, accuracy: 1); XCTAssertEqual(b.midY, l.midY, accuracy: 1)
      XCTAssertEqual(l.width, ("保存" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: r.buttonFont)]).width, accuracy: 2)
    }
  }

  func testFocusTraversalIncludesCloseAfterTheFormAndSkipsDisabledSave() throws {
    let r = try Reference.load()
    for valid in [false, true] {
      let expected = valid ? r.focusOrder : r.invalidFocusOrder
      XCTAssertEqual(RenameDialogField.order(valid: valid).map(\.rawValue), expected)
      for (index, name) in expected.enumerated() {
        let field = try XCTUnwrap(RenameDialogField(rawValue: name))
        XCTAssertEqual(RenameDialogField.next(after: field, valid: valid, reverse: false).rawValue,
          expected[(index + 1) % expected.count])
        XCTAssertEqual(RenameDialogField.next(after: field, valid: valid, reverse: true).rawValue,
          expected[(index + expected.count - 1) % expected.count])
      }
    }
    XCTAssertTrue(RenameDialogField.close.closesOnEnter)
    XCTAssertTrue(RenameDialogField.cancel.closesOnEnter)
    XCTAssertFalse(RenameDialogField.save.closesOnEnter)
    XCTAssertFalse(RenameDialogField.name.closesOnEnter)
  }

  func testSpaceActivatesOnlyOnceOnReleaseAndCancelsAcrossBlurOrDisable() {
    var press = RenameDialogSpacePress()
    XCTAssertFalse(press.up(enabled: true, focused: true))
    press.down(enabled: true, focused: true)
    XCTAssertTrue(press.armed)
    press.down(enabled: true, focused: true, repeatEvent: true)
    XCTAssertTrue(press.up(enabled: true, focused: true))
    XCTAssertFalse(press.up(enabled: true, focused: true))
    press.down(enabled: true, focused: true); press.cancel()
    XCTAssertFalse(press.up(enabled: true, focused: true))
    press.down(enabled: true, focused: true)
    XCTAssertFalse(press.up(enabled: false, focused: true))
    press.down(enabled: true, focused: true)
    XCTAssertFalse(press.up(enabled: true, focused: false))
    press.down(enabled: true, focused: true, repeatEvent: true)
    XCTAssertFalse(press.up(enabled: true, focused: true))
  }

  func testActualDialogMountKeepsEditableInitialTitleAndReferenceInputFont() async throws {
    let r = try Reference.load().expected
    for config in [TaskRenameDialog.Configuration.task, .browser(defaultTitle: "Default")] {
      let host = NSHostingView(rootView: TaskRenameDialog(initialTitle: "Original", save: { _ in }, close: {}, configuration: config))
      host.frame.size = .init(width: 800, height: 500); try await settle(host)
      func fields(_ view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
      }
      let input = try XCTUnwrap(fields(host).first { $0.isEditable })
      XCTAssertEqual(input.stringValue, "Original")
      XCTAssertEqual(input.font?.pointSize, r.inputFont)
      XCTAssertEqual(input.alignmentRect(forFrame: input.bounds).width,
        r.width - 2 * r.padding - 2 * (r.inputPadding + r.borderWidth), accuracy: 2)
    }
  }

  private func settle(_ host: NSView) async throws {
    try await Task.sleep(for: .milliseconds(200)); host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
  }
}

private struct RenameGeometryProbe: NSViewRepresentable {
  let view: NSView
  func makeNSView(context: Context) -> NSView { view }
  func updateNSView(_ nsView: NSView, context: Context) {}
}
