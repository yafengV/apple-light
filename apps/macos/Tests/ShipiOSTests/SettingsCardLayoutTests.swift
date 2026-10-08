import AppKit
import Observation
import SwiftUI
import XCTest
@testable import ShipiOS

final class SettingsCardLayoutTests: XCTestCase {
  @MainActor func testLabeledControlUsesTrailingCardEdgeAtWideAndNarrowWidths() async throws {
    _ = NSApplication.shared
    let label = NSView(), control = NSView()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let host = NSHostingView(rootView: SettingsForm {
      SettingsSection {
        LabeledContent {
          CardPositionProbe(view: control).frame(width: 100, height: 30)
        } label: {
          CardPositionProbe(view: label).frame(minWidth: 80, maxWidth: .infinity).frame(height: 30)
        }
      }
    }.settingsFormStyle())
    window.contentView = host
    for width in [CGFloat(700), 400] {
      window.setContentSize(NSSize(width: width, height: 400)); host.frame.size = NSSize(width: width, height: 400)
      try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
      let controlRect = control.convert(control.bounds, to: host)
      let labelRect = label.convert(label.bounds, to: host)
      XCTAssertEqual(labelRect.minX, 36, accuracy: 1)
      XCTAssertEqual(controlRect.maxX, width - 36, accuracy: 1)
      let row = try SettingsRowLayoutReference.load().expected
      let available = width - 72
      let minimum = min(row.controlMinimum, available * row.controlWidthFraction)
      XCTAssertEqual(controlRect.minX - labelRect.maxX, row.rowGap + minimum - 100, accuracy: 1)
      XCTAssertEqual(scrollViews(host).count, 1)
    }
  }

  private struct Reference: Decodable {
    struct Expected: Decodable {
      let sectionHeadingSize, sectionHeaderMinHeight, sectionHeaderBottomInset: CGFloat
      let cardRadius, cardBorderWidth, dividerInset, dividerHeight: CGFloat
      let rowHorizontalInset, rowVerticalInset, rowGap: CGFloat
    }
    let expected: Expected
  }

  @MainActor func testFormCardGeometryMatchesPublicComponentsAtWideAndNarrowWidths() async throws {
    _ = NSApplication.shared
    let url = try XCTUnwrap(Bundle.module.url(forResource: "settings_card_layout_reference_664", withExtension: "json", subdirectory: "Fixtures"))
    let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url)).expected
    let page = try SettingsPageLayoutReference.sidebarLayout()
    XCTAssertEqual(SettingsCardLayout.sectionHeadingSize, reference.sectionHeadingSize)
    XCTAssertEqual(SettingsCardLayout.radius, reference.cardRadius)
    XCTAssertEqual(SettingsCardLayout.borderWidth, reference.cardBorderWidth)
    XCTAssertEqual(SettingsCardLayout.dividerInset, reference.dividerInset)
    XCTAssertEqual(SettingsCardLayout.dividerHeight, reference.dividerHeight)
    XCTAssertEqual(SettingsCardLayout.rowGap, reference.rowGap)
    let first = NSView(), second = NSView(), third = NSView(), header = NSView()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let host = NSHostingView(rootView: SettingsForm {
      SettingsSection {
        CardPositionProbe(view: first).frame(height: 30)
        CardPositionProbe(view: second).frame(height: 30)
      } header: {
        CardPositionProbe(view: header).frame(height: reference.sectionHeaderMinHeight)
      }
      SettingsSection { CardPositionProbe(view: third).frame(height: 30) }
    }.settingsFormStyle().environment(\.settingsPageTitle, "参考表单"))
    window.contentView = host
    for width in [CGFloat(700), 400] {
      window.setContentSize(NSSize(width: width, height: 500))
      host.frame.size = NSSize(width: width, height: 500)
      try await Task.sleep(for: .milliseconds(200)); host.layoutSubtreeIfNeeded()
      func rect(_ view: NSView) -> NSRect { view.convert(view.bounds, to: host) }
      func top(_ view: NSView) -> CGFloat {
        let value = rect(view)
        return host.isFlipped ? value.minY : host.bounds.height - value.maxY
      }
      XCTAssertEqual(rect(header).minX, page.panelInset, accuracy: 1)
      XCTAssertEqual(rect(header).width, width - 2 * page.panelInset, accuracy: 1)
      XCTAssertEqual(rect(first).minX, page.panelInset + reference.rowHorizontalInset, accuracy: 1)
      XCTAssertEqual(rect(first).width, width - 2 * (page.panelInset + reference.rowHorizontalInset), accuracy: 1)
      XCTAssertEqual(top(first) - top(header) - header.bounds.height,
        reference.sectionHeaderBottomInset + reference.rowVerticalInset, accuracy: 1)
      XCTAssertEqual(top(second) - top(first) - first.bounds.height, reference.rowVerticalInset * 2, accuracy: 1)
      XCTAssertEqual(top(third) - top(second) - second.bounds.height,
        page.sectionSpacing + reference.rowVerticalInset * 2, accuracy: 1)
      XCTAssertEqual(scrollViews(host).count, 1)
      XCTAssertFalse(window.isVisible)
    }
  }

  @MainActor func testUntitledFormDoesNotCreateAnEmptyPageHeading() async throws {
    _ = NSApplication.shared
    let probe = NSView()
    let host = NSHostingView(rootView: SettingsForm {
      SettingsSection { CardPositionProbe(view: probe).frame(height: 30) }
    }.settingsFormStyle())
    host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
    let value = probe.convert(probe.bounds, to: host)
    let top = host.isFlipped ? value.minY : host.bounds.height - value.maxY
    XCTAssertEqual(top, SettingsPageLayout.horizontalInset + SettingsCardLayout.rowVerticalInset, accuracy: 1)
    XCTAssertEqual(scrollViews(host).count, 1)
  }

  @MainActor private func scrollViews(_ view: NSView) -> [NSScrollView] {
    (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews($0) }
  }

  @MainActor func testConditionalAndIdentifiedRowsKeepEditingIdentityAndSpacing() async throws {
    _ = NSApplication.shared
    let state = DynamicCardRows()
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 700, height: 500),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let host = NSHostingView(rootView: DynamicCardSurface(state: state))
    window.contentView = host
    try await settle(host)
    XCTAssertTrue(window.makeFirstResponder(state.field))
    let editor = try XCTUnwrap(state.field.currentEditor() as? NSTextView)
    editor.string = "保留编辑中的内容"; state.field.stringValue = editor.string
    editor.setSelectedRange(.init(location: 2, length: 3))
    for (show, ids) in [(true, [2, 1, 0]), (false, [0, 2]), (true, [1, 0, 2])] {
      state.showConditional = show; state.ids = ids
      try await settle(host)
      let rows = [state.editorRow] + (show ? [state.conditional] : []) + ids.map { state.rows[$0] }
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      func brightness(x: CGFloat, y: CGFloat) throws -> CGFloat {
        let color = try XCTUnwrap(bitmap.colorAt(x: Int(x * CGFloat(bitmap.pixelsWide) / host.bounds.width),
          y: Int(y * CGFloat(bitmap.pixelsHigh) / host.bounds.height))?.usingColorSpace(.sRGB))
        return (color.redComponent + color.greenComponent + color.blueComponent) / 3
      }
      for pair in zip(rows, rows.dropFirst()) {
        let first = pair.0.convert(pair.0.bounds, to: host)
        let second = pair.1.convert(pair.1.bounds, to: host)
        let gap = host.isFlipped ? second.minY - first.maxY : first.minY - second.maxY
        XCTAssertEqual(gap, 24, accuracy: 1, "Conditional / ForEach rows need independent insets")
        let bottom = host.isFlipped ? first.maxY : host.bounds.height - first.minY
        let dividerY = bottom + 11
        let line = try brightness(x: 350, y: dividerY)
        let fill = try brightness(x: 350, y: dividerY - 3)
        XCTAssertGreaterThan(abs(line - fill), 0.02, "Each dynamic row boundary must draw a divider")
        XCTAssertEqual(try brightness(x: 24, y: dividerY),
          try brightness(x: 24, y: dividerY - 3), accuracy: 0.01, "Divider must stay inset from card edges")
      }
      XCTAssertTrue(window.firstResponder === editor)
      XCTAssertTrue(state.field.currentEditor() === editor)
      XCTAssertEqual(editor.string, "保留编辑中的内容")
      XCTAssertEqual(editor.selectedRange(), .init(location: 2, length: 3))
      XCTAssertEqual(scrollViews(host).count, 1)
    }
    XCTAssertFalse(window.isVisible)
  }

  @MainActor func testEmbeddedSectionKeepsHeaderFooterAndDoesNotAddScrollContainer() async throws {
    _ = NSApplication.shared
    let header = NSView(), row = NSView(), footer = NSView()
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let host = NSHostingView(rootView: SettingsForm {
      SettingsSection {
        CardPositionProbe(view: row).frame(height: 30)
      } header: {
        CardPositionProbe(view: header).frame(height: 46)
      } footer: {
        CardPositionProbe(view: footer).frame(height: 20)
      }
    }.environment(\.settingsFormEmbedded, true)
      .environment(\.settingsPageTitle, "不应重复的页面标题"))
    window.contentView = host; try await settle(host)
    func rect(_ view: NSView) -> NSRect { view.convert(view.bounds, to: host) }
    func top(_ view: NSView) -> CGFloat {
      let value = rect(view); return host.isFlipped ? value.minY : host.bounds.height - value.maxY
    }
    XCTAssertEqual(rect(header).minX, 0, accuracy: 1)
    XCTAssertEqual(rect(header).width, 400, accuracy: 1)
    XCTAssertEqual(rect(row).minX, 16, accuracy: 1)
    XCTAssertEqual(rect(footer).minX, 16, accuracy: 1)
    XCTAssertEqual(top(row) - top(header) - 46, 18, accuracy: 1)
    XCTAssertEqual(top(footer) - top(row) - 30, 18, accuracy: 1)
    XCTAssertEqual(scrollViews(host).count, 0)
    XCTAssertFalse(window.isVisible)
  }

  @MainActor private func settle(_ view: NSView) async throws {
    try await Task.sleep(for: .milliseconds(150)); view.layoutSubtreeIfNeeded()
  }
}

@MainActor @Observable private final class DynamicCardRows {
  var showConditional = false
  var ids = [0, 1]
  let field = NSTextField(string: "原始内容")
  let editorRow = NSView()
  let conditional = NSView()
  let rows = [NSView(), NSView(), NSView()]
  init() {
    field.frame = .init(x: 0, y: 0, width: 200, height: 24)
    editorRow.addSubview(field)
  }
}

private struct DynamicCardSurface: View {
  let state: DynamicCardRows
  var body: some View {
    SettingsForm {
      SettingsSection {
        CardPositionProbe(view: state.editorRow).frame(height: 30)
        if state.showConditional { CardPositionProbe(view: state.conditional).frame(height: 30) }
        ForEach(state.ids, id: \.self) { id in CardPositionProbe(view: state.rows[id]).frame(height: 30) }
      }
    }
  }
}

private struct CardPositionProbe: NSViewRepresentable {
  let view: NSView
  func makeNSView(context: Context) -> NSView { view }
  func updateNSView(_ nsView: NSView, context: Context) {}
}
