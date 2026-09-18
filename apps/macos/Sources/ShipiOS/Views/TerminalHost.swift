import SwiftTerm
import SwiftUI

struct TerminalHost: NSViewRepresentable {
  @Environment(\.appAppearance) private var appearance
  let session: TerminalSession
  let focus: TerminalFocusRequest?
  let canFocus: (TerminalFocusRequest) -> Bool
  final class Coordinator { var handled: UUID? }
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSView { session.view }
  func updateNSView(_ view: NSView, context: Context) {
    guard let view = view as? LocalProcessTerminalView else { return }
    let font = appearance.nativeFont(size: 12, code: true)
    if view.font != font { view.font = font }
    view.nativeBackgroundColor = appearance.backgroundHex.flatMap(AppearancePreferences.color).map(NSColor.init)
      ?? .textBackgroundColor
    view.nativeForegroundColor = appearance.foregroundHex.flatMap(AppearancePreferences.color).map(NSColor.init)
      ?? .textColor
    if let focus, context.coordinator.handled != focus.id {
      context.coordinator.handled = focus.id
      DispatchQueue.main.async {
        if canFocus(focus), view.window?.isKeyWindow == true,
          view.window?.attachedSheet == nil { view.window?.makeFirstResponder(view) }
      }
    }
  }
}
