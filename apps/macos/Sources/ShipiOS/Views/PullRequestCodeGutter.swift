import AppKit
import Observation
import SwiftUI

/// Window-local drag routing crosses gutter cells without capturing code text selection.
@MainActor @Observable final class PullRequestCodeSelection {
  var first: GitHubPRCodePoint?
  var last: GitHubPRCodePoint?
  @ObservationIgnored private var cells: [ObjectIdentifier: WeakCell] = [:]
  private struct WeakCell { weak var view: PullRequestCodeGutterView? }
  func register(_ view: PullRequestCodeGutterView) { cells[ObjectIdentifier(view)] = .init(view: view) }
  func unregister(_ view: PullRequestCodeGutterView) { cells[ObjectIdentifier(view)] = nil }
  var liveCells: [PullRequestCodeGutterView] { cells.values.compactMap(\.view).filter { $0.enabled } }
  func begin(_ point: GitHubPRCodePoint, extending: Bool) {
    if !extending || first == nil { first = point }; last = point
  }
  func clear() { first = nil; last = nil }
  func position(path: String) -> GitHubPRCommentPosition? {
    guard let first, let last else { return nil }; return GitHubPRCodePoint.position(path: path, from: first, to: last)
  }
  func contains(_ point: GitHubPRCodePoint) -> Bool {
    guard let first, let last else { return false }
    if first.side == last.side {
      return point.side == first.side && (min(first.line, last.line)...max(first.line, last.line)).contains(point.line)
    }
    return (min(first.row, last.row)...max(first.row, last.row)).contains(point.row)
  }
  func nearest(to location: NSPoint, in window: NSWindow) -> PullRequestCodeGutterView? {
    liveCells.filter { $0.window === window && !$0.isHiddenOrHasHiddenAncestor }.min { first, second in
      @MainActor func distance(_ view: NSView) -> CGFloat {
        let rect = view.convert(view.bounds, to: nil)
        let dx = max(0, max(rect.minX - location.x, location.x - rect.maxX))
        let dy = max(0, max(rect.minY - location.y, location.y - rect.maxY))
        return dy * 10_000 + dx
      }
      return distance(first) < distance(second)
    }
  }
}

struct PullRequestCodeGutter: NSViewRepresentable {
  let point: GitHubPRCodePoint
  let selection: PullRequestCodeSelection
  let enabled: Bool
  let selected: Bool
  let commit: (GitHubPRCommentPosition) -> Void
  let path: String
  func makeNSView(context: Context) -> PullRequestCodeGutterView { PullRequestCodeGutterView() }
  func updateNSView(_ view: PullRequestCodeGutterView, context: Context) {
    if view.selection !== selection { view.selection?.unregister(view); view.selection = selection; selection.register(view) }
    view.point = point; view.enabled = enabled; view.selected = selected; view.commit = commit; view.path = path
    view.setAccessibilityLabel("在 \(path) 的 \(point.side == .left ? "旧" : "新")文件第 \(point.line) 行评论")
    view.setAccessibilityValue(selected ? "已选择" : "")
    view.needsDisplay = true
  }
  static func dismantleNSView(_ view: PullRequestCodeGutterView, coordinator: ()) { view.selection?.unregister(view) }
}

@MainActor final class PullRequestCodeGutterView: NSView {
  var point = GitHubPRCodePoint(side: .right, line: 1)
  weak var selection: PullRequestCodeSelection?
  var enabled = false { didSet { setAccessibilityEnabled(enabled) } }
  var selected = false
  var path = ""
  var commit: ((GitHubPRCommentPosition) -> Void)?
  private var hover = false
  private var tracking: NSTrackingArea?
  override var acceptsFirstResponder: Bool { enabled }
  override var isFlipped: Bool { true }
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect); setAccessibilityElement(true); setAccessibilityRole(.button)
    setAccessibilityHelp("点击评论；拖动或 Shift 点击选择范围；Shift 与方向键扩展，Return 评论，Escape 清除选择。")
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
    addTrackingArea(area); tracking = area
  }
  override func mouseEntered(with event: NSEvent) { hover = true; needsDisplay = true }
  override func mouseExited(with event: NSEvent) { hover = false; needsDisplay = true }
  override func mouseDown(with event: NSEvent) {
    guard enabled else { return }
    window?.makeFirstResponder(self); selection?.begin(point, extending: event.modifierFlags.contains(.shift)); needsDisplay = true
  }
  override func mouseDragged(with event: NSEvent) {
    guard enabled, let window, let selection, let cell = selection.nearest(to: event.locationInWindow, in: window) else { return }
    selection.last = cell.point
  }
  override func mouseUp(with event: NSEvent) { finish() }
  private func finish() {
    guard enabled, let position = selection?.position(path: path) else { return }; commit?(position)
  }
  override func keyDown(with event: NSEvent) {
    guard enabled else { return }
    if event.keyCode == 53 { selection?.clear(); return }
    if [36, 76, 49].contains(event.keyCode) {
      if selection?.last == nil { selection?.begin(point, extending: false) }; finish(); return
    }
    if [123, 124].contains(event.keyCode), let selection, let window {
      let side: GitHubPRCommentPosition.Side = event.keyCode == 123 ? .left : .right
      guard side != point.side else { return }
      let rect = convert(bounds, to: nil)
      guard let other = selection.liveCells.first(where: {
        $0.window === window && $0.point.side == side && abs($0.convert($0.bounds, to: nil).midY - rect.midY) < 1
      }) else { return }
      if event.modifierFlags.contains(.shift) {
        if selection.first == nil { selection.begin(point, extending: false) }; selection.last = other.point
      } else { selection.clear() }
      window.makeFirstResponder(other); return
    }
    if [125, 126].contains(event.keyCode), let selection {
      let ordered = selection.liveCells.filter { $0.point.side == point.side }.sorted { $0.point.row < $1.point.row }
      guard let index = ordered.firstIndex(where: { $0 === self }) else { return }
      let next = index + (event.keyCode == 125 ? 1 : -1)
      guard ordered.indices.contains(next) else { return }
      if event.modifierFlags.contains(.shift) {
        if selection.first == nil { selection.begin(point, extending: false) }; selection.last = ordered[next].point
      } else { selection.clear() }
      window?.makeFirstResponder(ordered[next]); return
    }
    super.keyDown(with: event)
  }
  override func accessibilityPerformPress() -> Bool {
    guard enabled else { return false }; selection?.begin(point, extending: false); finish(); return true
  }
  override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
  override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
  override func draw(_ dirtyRect: NSRect) {
    guard enabled, hover || window?.firstResponder === self else { return }
    let rect = NSRect(x: 1, y: 0, width: 13, height: 13)
    NSColor.controlAccentColor.setFill(); NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
    let symbol = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
    symbol?.draw(in: rect.insetBy(dx: 2, dy: 2))
  }
}
