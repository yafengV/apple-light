import AppKit

/// AppKit's bottom-left coordinates for the Codex popout's bottom-aligned surfaces.
enum PopoutWindowPlacement {
  static let homeSize = NSSize(width: 470, height: 290)
  static let threadSize = NSSize(width: 470, height: 640)
  static let threadMinimumSize = NSSize(width: 400, height: 400)
  static let threadTopInset: CGFloat = 52

  static func initialThread(in visible: NSRect,
    size: NSSize = PopoutWindowPlacement.threadSize) -> NSRect {
    let width = min(max(size.width, threadMinimumSize.width), visible.width)
    let height = min(max(size.height, threadMinimumSize.height), visible.height)
    return NSRect(x: clamp(visible.midX - width / 2, visible.minX, visible.maxX - width),
      y: clamp(visible.maxY - threadTopInset - height, visible.minY, visible.maxY - height),
      width: width, height: height)
  }

  static func initialHome(in visible: NSRect,
    size: NSSize = PopoutWindowPlacement.homeSize,
    threadSize: NSSize = PopoutWindowPlacement.threadSize) -> NSRect {
    let thread = initialThread(in: visible, size: threadSize)
    let width = min(size.width, visible.width)
    let height = min(size.height, visible.height)
    return NSRect(x: clamp(visible.midX - width / 2, visible.minX, visible.maxX - width),
      y: clamp(thread.minY, visible.minY, visible.maxY - height),
      width: width, height: height)
  }

  static func thread(alignedTo home: NSRect, in visible: NSRect,
    size: NSSize) -> NSRect {
    let width = min(max(size.width, threadMinimumSize.width), visible.width)
    let height = min(max(size.height, threadMinimumSize.height), visible.height)
    return NSRect(x: clamp(home.midX - width / 2, visible.minX, visible.maxX - width),
      y: clamp(home.minY, visible.minY, visible.maxY - height),
      width: width, height: height)
  }

  static func home(alignedTo thread: NSRect, in visible: NSRect,
    height: CGFloat) -> NSRect {
    let width = min(max(thread.width, threadMinimumSize.width), visible.width)
    let height = min(height, visible.height)
    return NSRect(x: clamp(thread.midX - width / 2, visible.minX, visible.maxX - width),
      y: clamp(thread.minY, visible.minY, visible.maxY - height),
      width: width, height: height)
  }

  private static func clamp(_ value: CGFloat, _ minimum: CGFloat, _ maximum: CGFloat) -> CGFloat {
    min(max(value, minimum), maximum)
  }
}
