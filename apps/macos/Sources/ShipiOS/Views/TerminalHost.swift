import SwiftTerm
import SwiftUI

/// The process outlives its SwiftUI host; retry pending focus after the same view is reattached.
final class SessionTerminalView: LocalProcessTerminalView {
  weak var focusCoordinator: TerminalHost.Coordinator?
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    focusCoordinator?.scheduleFocus()
  }
}

struct TerminalHost: NSViewRepresentable {
  @Environment(\.appAppearance) private var appearance
  let session: TerminalSession
  let focus: TerminalFocusRequest?
  let canFocus: (TerminalFocusRequest) -> Bool
  @MainActor final class Coordinator {
    private weak var view: SessionTerminalView?
    private var request: TerminalFocusRequest?
    private var canFocus: ((TerminalFocusRequest) -> Bool)?
    private(set) var handled: UUID?

    func update(view: SessionTerminalView, request: TerminalFocusRequest?,
      canFocus: @escaping (TerminalFocusRequest) -> Bool) {
      if self.view !== view { detach() }
      self.view = view
      self.request = request
      self.canFocus = canFocus
      view.focusCoordinator = self
      scheduleFocus()
    }

    func scheduleFocus() {
      DispatchQueue.main.async { [weak self] in self?.applyFocus() }
    }

    private func applyFocus() {
      guard let view, view.focusCoordinator === self,
        let request, handled != request.id, canFocus?(request) == true,
        let window = view.window, window.isKeyWindow, window.attachedSheet == nil else { return }
      if window.makeFirstResponder(view) { handled = request.id }
    }

    func detach() {
      if view?.focusCoordinator === self { view?.focusCoordinator = nil }
      view = nil
      request = nil
      canFocus = nil
    }
  }
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSView { session.view }
  func updateNSView(_ view: NSView, context: Context) {
    guard let view = view as? SessionTerminalView else { return }
    let font = appearance.nativeFont(size: 12, code: true)
    if view.font != font { view.font = font }
    view.nativeBackgroundColor = appearance.backgroundHex.flatMap(AppearancePreferences.color).map(NSColor.init)
      ?? .textBackgroundColor
    view.nativeForegroundColor = appearance.foregroundHex.flatMap(AppearancePreferences.color).map(NSColor.init)
      ?? .textColor
    context.coordinator.update(view: view, request: focus, canFocus: canFocus)
  }
  static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
    coordinator.detach()
  }
}
