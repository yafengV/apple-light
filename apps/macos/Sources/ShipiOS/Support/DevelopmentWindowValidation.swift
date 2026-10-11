#if DEBUG
import AppKit

/// Sets up a visible product window for the fixed delivery matrix. Default
/// placement alone can be overridden by macOS window restoration.
enum DevelopmentWindowValidation {
  static func requestedSize(arguments: [String]) -> NSSize? {
    guard arguments.filter({ $0 == "--data-root" }).count == 1,
      let rootIndex = arguments.firstIndex(of: "--data-root"),
      arguments.indices.contains(rootIndex + 1), arguments[rootIndex + 1].hasPrefix("/"),
      arguments.filter({ $0 == "--validation-window-size" }).count == 1,
      let sizeIndex = arguments.firstIndex(of: "--validation-window-size"),
      arguments.indices.contains(sizeIndex + 1) else { return nil }
    switch arguments[sizeIndex + 1] {
    case "1000x700": return .init(width: 1000, height: 700)
    case "1280x800": return .init(width: 1280, height: 800)
    default: return nil
    }
  }

  @MainActor static func prepare(arguments: [String], dataRoot: URL,
    windows: [NSWindow]) throws {
    guard let size = requestedSize(arguments: arguments),
      let window = windows.first(where: { $0.identifier?.rawValue == "main" && $0.isVisible }),
      !window.styleMask.contains(.fullScreen), window.attachedSheet == nil else { return }
    // Keep the existing top-left position and responder. Do not activate an app,
    // hide another window, or manufacture foreground evidence.
    let frame = NSRect(x: window.frame.minX, y: window.frame.maxY - size.height,
      width: size.width, height: size.height)
    window.setFrame(frame, display: true)
    let actual = window.frame
    let record: [String: Any] = [
      "requestedWidth": size.width, "requestedHeight": size.height,
      "actualWidth": actual.width, "actualHeight": actual.height,
      "contentWidth": window.contentLayoutRect.width,
      "contentHeight": window.contentLayoutRect.height,
      "backingScale": window.backingScaleFactor,
      "visible": window.isVisible, "key": window.isKeyWindow,
      "active": NSApp.isActive, "pid": ProcessInfo.processInfo.processIdentifier,
      "matchesRequestedFrame": actual.size == size,
    ]
    let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: dataRoot.appendingPathComponent("validation-window.json"), options: .atomic)
  }
}
#endif
