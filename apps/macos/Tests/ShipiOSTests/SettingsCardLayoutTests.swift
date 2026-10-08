import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

final class SettingsCardLayoutTests: XCTestCase {
  @MainActor func testLabeledControlUsesTrailingCardEdgeAtWideAndNarrowWidths() async throws {
    guard #available(macOS 15.0, *) else { throw XCTSkip("Section decomposition requires macOS 15") }
    _ = NSApplication.shared
    let label = NSView(), control = NSView()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let host = NSHostingView(rootView: SettingsForm {
      Section {
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
      XCTAssertEqual(controlRect.minX - labelRect.maxX, 24, accuracy: 1)
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
    guard #available(macOS 15.0, *) else { throw XCTSkip("Section decomposition requires macOS 15") }
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
      Section {
        CardPositionProbe(view: first).frame(height: 30)
        CardPositionProbe(view: second).frame(height: 30)
      } header: {
        CardPositionProbe(view: header).frame(height: reference.sectionHeaderMinHeight)
      }
      Section { CardPositionProbe(view: third).frame(height: 30) }
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
    guard #available(macOS 15.0, *) else { throw XCTSkip("Section decomposition requires macOS 15") }
    _ = NSApplication.shared
    let probe = NSView()
    let host = NSHostingView(rootView: SettingsForm {
      Section { CardPositionProbe(view: probe).frame(height: 30) }
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
}

private struct CardPositionProbe: NSViewRepresentable {
  let view: NSView
  func makeNSView(context: Context) -> NSView { view }
  func updateNSView(_ nsView: NSView, context: Context) {}
}
