import SwiftTerm
import SwiftUI

/// The process outlives its SwiftUI host; retry pending focus after the same view is reattached.
final class SessionTerminalView: LocalProcessTerminalView {
  weak var focusCoordinator: TerminalHost.Coordinator?
  private var baseFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
  private(set) var fontZoomOffset: CGFloat = 0

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    focusCoordinator?.scheduleFocus()
  }

  func applyBaseFont(_ font: NSFont) {
    baseFont = font
    applyZoomedFont()
  }

  func zoomFont(by step: CGFloat) {
    let target = min(32, max(8, baseFont.pointSize + fontZoomOffset + step))
    fontZoomOffset = target - baseFont.pointSize
    applyZoomedFont()
  }

  func resetFontZoom() {
    fontZoomOffset = 0
    applyZoomedFont()
  }

  private func applyZoomedFont() {
    let desired = NSFontManager.shared.convert(baseFont, toSize: baseFont.pointSize + fontZoomOffset)
    if self.font != desired { self.font = desired }
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = NSMenu(title: "终端")
    let copyItem = menu.addItem(withTitle: "复制", action: #selector(copy(_:)), keyEquivalent: "")
    copyItem.target = self
    copyItem.isEnabled = validateUserInterfaceItem(copyItem)
    let pasteItem = menu.addItem(withTitle: "粘贴", action: #selector(paste(_:)), keyEquivalent: "")
    pasteItem.target = self
    menu.addItem(.separator())
    let selectItem = menu.addItem(withTitle: "全选", action: #selector(selectAll(_:)), keyEquivalent: "")
    selectItem.target = self
    menu.addItem(.separator())
    for (title, action) in [
      ("放大字体", #selector(increaseFont(_:))),
      ("缩小字体", #selector(decreaseFont(_:))),
      ("恢复默认字号", #selector(resetFontSize(_:))),
    ] {
      let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
      item.target = self
    }
    return menu
  }

  override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
    switch item.action {
    case #selector(increaseFont(_:)), #selector(decreaseFont(_:)), #selector(resetFontSize(_:)):
      return true
    default:
      return super.validateUserInterfaceItem(item)
    }
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard let window, window.isKeyWindow, window.firstResponder === self else {
      return super.performKeyEquivalent(with: event)
    }
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let key = event.charactersIgnoringModifiers?.lowercased()
    switch (key, modifiers) {
    case ("=", [.command]), ("+", [.command]), ("=", [.command, .shift]), ("+", [.command, .shift]):
      zoomFont(by: 1); return true
    case ("-", [.command]):
      zoomFont(by: -1); return true
    case ("0", [.command]):
      resetFontZoom(); return true
    default:
      return super.performKeyEquivalent(with: event)
    }
  }

  @objc private func increaseFont(_ sender: Any?) { zoomFont(by: 1) }
  @objc private func decreaseFont(_ sender: Any?) { zoomFont(by: -1) }
  @objc private func resetFontSize(_ sender: Any?) { resetFontZoom() }
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
    view.applyBaseFont(font)
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
