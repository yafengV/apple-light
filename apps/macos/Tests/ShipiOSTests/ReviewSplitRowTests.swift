import AppKit
import SwiftUI
import XCTest

@testable import ShipiOS

final class ReviewSplitRowTests: XCTestCase {
  @MainActor func testSplitColumnsKeepTheSameOriginForShortLongAndMissingLines() {
    _ = NSApplication.shared
    for width: CGFloat in [720, 1_000] {
      for wrap in [false, true] {
        let longLine = ReviewDiffLine(id: 2,
          text: "+" + String(repeating: "long changed value ", count: 8),
          kind: .addition, oldLine: nil, newLine: 3)
        let columnWidth = wrap ? 0 : ReviewSplitMetrics.minimumColumnWidth(
          lines: [longLine], appearance: AppearancePreferences())
        let host = NSHostingView(rootView:
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(0..<3) { index in
              ReviewSplitRow(wrap: wrap, minimumColumnWidth: columnWidth) {
                if index == 0 {
                  ReviewCodeLine(line: .init(id: index, text: "-old", kind: .deletion,
                    oldLine: 1, newLine: nil), addComment: {}, openLine: {}, side: .old, wrap: wrap)
                } else { Color.clear.frame(maxWidth: .infinity).frame(minHeight: 20) }
              } right: {
                ReviewCodeLine(line: .init(id: index, text: "+" + (index == 2
                  ? String(repeating: "long changed value ", count: 8) : "short"),
                  kind: .addition, oldLine: nil, newLine: index + 1),
                  addComment: {}, openLine: {}, side: .new, wrap: wrap)
                  .background(SplitFrameProbe(name: "right-\(index)"))
              }
            }
          }.frame(minWidth: width, alignment: .leading))
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        let frames = probeFrames(in: host, relativeTo: host)
        let right = (0..<3).compactMap { frames["right-\($0)"] }
        XCTAssertEqual(right.count, 3)
        guard right.count == 3 else { continue }
        for frame in right {
          XCTAssertEqual(frame.minX, right[0].minX, accuracy: 1,
            "Column moved at width \(width), wrap \(wrap)")
          XCTAssertEqual(frame.width, right[0].width, accuracy: 1)
        }
        XCTAssertGreaterThanOrEqual(right[0].minX, width / 2 - 1)
      }
    }
  }

  @MainActor func testWrappedRowFitsTheViewportAndKeepsBothColumns() {
    _ = NSApplication.shared
    let line = ReviewDiffLine(id: 0, text: "+" + String(repeating: "changed value ", count: 60),
      kind: .addition, oldLine: nil, newLine: 1)
    let host = NSHostingView(rootView: ReviewSplitRow(wrap: true) {
      Color.clear.frame(maxWidth: .infinity).frame(minHeight: 20)
        .background(SplitFrameProbe(name: "left"))
    } right: {
      ReviewCodeLine(line: line, addComment: {}, openLine: {}, side: .new, wrap: true)
        .background(SplitFrameProbe(name: "right"))
    }.frame(width: 500))
    host.frame.size = host.fittingSize
    host.layoutSubtreeIfNeeded()
    let frames = probeFrames(in: host, relativeTo: host)
    guard let left = frames["left"], let right = frames["right"] else {
      return XCTFail("Native column measurements missing")
    }
    XCTAssertEqual(left.width, right.width, accuracy: 1)
    XCTAssertEqual(right.maxX, 500, accuracy: 1)
    XCTAssertGreaterThan(right.height, 40)
  }

  @MainActor private func probeFrames(in view: NSView, relativeTo host: NSView) -> [String: CGRect] {
    var result: [String: CGRect] = [:]
    if let name = view.identifier?.rawValue, name.hasPrefix("split-probe-") {
      result[String(name.dropFirst("split-probe-".count))] = view.convert(view.bounds, to: host)
    }
    for child in view.subviews { result.merge(probeFrames(in: child, relativeTo: host)) { _, new in new } }
    return result
  }
}

private struct SplitFrameProbe: NSViewRepresentable {
  let name: String
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    view.identifier = NSUserInterfaceItemIdentifier("split-probe-" + name)
    return view
  }
  func updateNSView(_ nsView: NSView, context: Context) {}
}
