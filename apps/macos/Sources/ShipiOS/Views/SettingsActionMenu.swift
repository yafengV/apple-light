import AppKit
import SwiftUI

/// A compact action menu with a real native responder for keyboard restoration.
struct SettingsActionMenu: NSViewRepresentable {
  let title: String
  let actionTitle: String
  var destructive = false
  var actionSystemImage: String?
  var focusRequest: UUID?
  let action: () -> Void
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.appAppearance) private var appearance

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> SettingsMenuControl {
    let button = SettingsMenuControl(frame: .zero, pullsDown: true)
    button.isBordered = false
    button.imagePosition = .imageOnly
    (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
    button.menu?.autoenablesItems = false
    button.addItem(withTitle: "")
    button.item(at: 0)?.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
    button.addItem(withTitle: actionTitle)
    button.target = context.coordinator
    button.action = #selector(Coordinator.selected(_:))
    return button
  }

  func updateNSView(_ button: SettingsMenuControl, context: Context) {
    button.isEnabled = isEnabled
    button.font = appearance.nativeFont(size: 13)
    button.contentTintColor = NSColor(appearance.foregroundColor)
    button.setAccessibilityLabel(title)
    button.toolTip = title
    button.item(at: 1)?.title = actionTitle
    button.item(at: 1)?.isEnabled = isEnabled
    let foreground: NSColor = destructive ? .systemRed : .labelColor
    button.item(at: 1)?.attributedTitle = NSAttributedString(string: actionTitle,
      attributes: [.foregroundColor: foreground, .font: appearance.nativeFont(size: 13)])
    button.item(at: 1)?.image = actionSystemImage.flatMap {
      NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(paletteColors: [foreground]))
    }
    context.coordinator.update(button, enabled: isEnabled, request: focusRequest, action: action)
  }

  static func dismantleNSView(_ button: SettingsMenuControl, coordinator: Coordinator) {
    coordinator.stop()
    button.active = false
    button.target = nil
  }

  final class Coordinator: NSObject {
    private var active = true
    private var enabled = true
    private var lastRequest: UUID?
    private var generation = UUID()
    private var action: (() -> Void)?

    func update(_ button: SettingsMenuControl, enabled: Bool, request: UUID?, action: @escaping () -> Void) {
      self.action = action
      if self.enabled != enabled { generation = UUID() }
      self.enabled = enabled
      guard request != lastRequest else { return }
      lastRequest = request
      generation = UUID()
      let token = generation
      guard request != nil, enabled else { return }
      DispatchQueue.main.async { [weak self, weak button] in
        guard let self, self.active, self.enabled, self.generation == token,
          let button, button.acceptsFirstResponder, let window = button.window else { return }
        window.makeFirstResponder(button)
      }
    }

    @objc func selected(_ button: SettingsMenuControl) {
      guard active, enabled, button.acceptsFirstResponder,
        button.indexOfSelectedItem == 1 else { return }
      action?()
    }

    func stop() {
      active = false
      generation = UUID()
      action = nil
    }
  }
}
