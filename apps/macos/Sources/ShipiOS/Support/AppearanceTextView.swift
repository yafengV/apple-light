import AppKit

/// CSS `antialiased` selects grayscale font antialiasing. Turning the preference
/// off restores the renderer's defaults; it must never request jagged text.
enum AppearanceFontSmoothing {
  static func draw(enabled: Bool, in context: CGContext?, _ body: () -> Void) {
    guard enabled, let context else { body(); return }
    context.saveGState()
    defer { context.restoreGState() }
    context.setShouldAntialias(true)
    context.setShouldSmoothFonts(false)
    body()
  }
}

/// Own only our text surfaces, including their placeholder drawing. Each
/// representable supplies the preference through its SwiftUI environment.
/// There are no process-wide defaults, method replacements or external pages.
class AppearanceTextView: NSTextView {
  var useFontSmoothing = true {
    didSet { if useFontSmoothing != oldValue { needsDisplay = true } }
  }

  final override func draw(_ dirtyRect: NSRect) {
    AppearanceFontSmoothing.draw(enabled: useFontSmoothing, in: NSGraphicsContext.current?.cgContext) {
      drawTextSurface(dirtyRect)
    }
  }

  func drawTextSurface(_ dirtyRect: NSRect) { super.draw(dirtyRect) }
}
