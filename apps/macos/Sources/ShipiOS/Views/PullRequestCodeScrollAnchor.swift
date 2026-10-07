import AppKit
import SwiftUI

/// ScrollViewProxy can address the nested horizontal code scroller instead of
/// the page. Convert the target's native frame into the vertical document only.
struct PullRequestCodeScrollAnchor: NSViewRepresentable {
  let request: UUID?
  var centered = true
  var topInset: CGFloat = 0
  func makeNSView(context: Context) -> PullRequestCodeScrollAnchorView { .init() }
  func updateNSView(_ view: PullRequestCodeScrollAnchorView, context: Context) {
    view.centered = centered; view.topInset = topInset; view.request = request
  }
  static func dismantleNSView(_ view: PullRequestCodeScrollAnchorView, coordinator: ()) { view.request = nil }
}

@MainActor final class PullRequestCodeScrollAnchorView: NSView {
  var centered = true
  var topInset: CGFloat = 0
  var request: UUID? { didSet { if request != oldValue { schedule() } } }
  private var positioning: Task<Void, Never>?
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect); setAccessibilityElement(false)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil { positioning?.cancel(); positioning = nil } else { schedule() }
  }
  private func schedule() {
    positioning?.cancel(); positioning = nil
    guard let request else { return }
    positioning = Task { [weak self] in
      // Match the reference's 200 attempts at 50 ms intervals: a lazy file can
      // take longer than the first layout passes to materialize its target.
      // Retry waits do not retain a removed target or window.
      for _ in 0..<200 {
        do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        guard let self, self.request == request, !Task.isCancelled, self.window != nil else { return }
        if self.position() {
          // The reference positions again on the next animation frame. Allow
          // AppKit/SwiftUI one frame to settle before accepting the location.
          do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
          guard self.request == request, !Task.isCancelled, self.window != nil else { return }
          if self.position() { return }
        }
      }
    }
  }
  private func position() -> Bool {
    var ancestor = superview
    while let view = ancestor {
      if let scroll = view as? NSScrollView, scroll.hasVerticalScroller,
        let document = scroll.documentView {
        document.layoutSubtreeIfNeeded()
        let rect = convert(bounds, to: document), clip = scroll.contentView
        guard bounds.height > 0, clip.bounds.height > 0, document.bounds.height > 0 else { return false }
        let wanted = centered ? rect.midY - clip.bounds.height / 2 : rect.minY - topInset
        let minimum = document.bounds.minY
        let maximum = max(minimum, document.bounds.maxY - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(maximum, max(minimum, wanted))))
        scroll.reflectScrolledClipView(clip)
        // A positive target frame alone is insufficient: a still-growing lazy
        // document can clamp the requested offset before the line is reachable.
        // A gutter may be outside the horizontal viewport; only vertical
        // visibility determines whether this vertical navigation is complete.
        return rect.maxY > clip.bounds.minY && rect.minY < clip.bounds.maxY
      }
      ancestor = view.superview
    }
    return false
  }
}
