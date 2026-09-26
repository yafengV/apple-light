import CoreGraphics

/// The header action toggles a popover at narrow widths and a pinned panel otherwise.
struct TaskSummaryPresentation: Equatable {
  enum Mode: Equatable { case overlay, shift, gutter }

  private(set) var mode: Mode = .overlay
  private(set) var isPinned = false
  private(set) var isPopoverOpen = false

  var showsInline: Bool { isPinned && mode != .overlay }
  var showsPopover: Bool { isPopoverOpen && mode == .overlay }
  var isVisible: Bool { showsInline || showsPopover }

  mutating func resize(to contentWidth: CGFloat) {
    // Codex uses (contentWidth - 736) / 2 to select these three layouts.
    let next: Mode
    if !contentWidth.isFinite || contentWidth < 1_096 { next = .overlay }
    else if contentWidth < 1_536 { next = .shift }
    else { next = .gutter }
    guard next != mode else { return }
    mode = next
    // A pinned panel can reappear when widening, but resizing must not open a popover.
    isPopoverOpen = false
  }

  mutating func toggle() {
    if mode == .overlay { isPopoverOpen.toggle() }
    else { isPinned.toggle() }
  }

  mutating func close() {
    if mode == .overlay { isPopoverOpen = false }
    else { isPinned = false }
  }

  mutating func dismissPopover() { isPopoverOpen = false }
}
