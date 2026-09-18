import AppKit
import SwiftUI

struct SettingsDropdownOption<Value: Hashable>: Equatable {
  let value: Value
  let title: String
  var selected = false
  var systemImage: String?
  var help: String?
  var enabled = true
}

enum SettingsDropdownItem<Value: Hashable>: Equatable {
  case section(String), separator, option(SettingsDropdownOption<Value>)
}

/// Flat native menu sections can retain independent checkmarks (type and sort).
struct SettingsDropdownMenu<Value: Hashable>: NSViewRepresentable {
  let title: String
  let accessibilityLabel: String
  let systemImage: String
  var compact = false
  let items: [SettingsDropdownItem<Value>]
  let onSelect: (Value) -> Void
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.appAppearance) private var appearance

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> SettingsMenuControl {
    let button = SettingsMenuControl(frame: .zero, pullsDown: true)
    button.imagePosition = .imageLeft
    button.lineBreakMode = .byTruncatingTail
    (button.cell as? NSPopUpButtonCell)?.altersStateOfSelectedItem = false
    button.menu?.autoenablesItems = false
    button.target = context.coordinator
    button.action = #selector(Coordinator.selected(_:))
    return button
  }

  func updateNSView(_ button: SettingsMenuControl, context: Context) {
    let coordinator = context.coordinator
    coordinator.parent = self
    button.imagePosition = compact ? .imageOnly : .imageLeft
    button.isBordered = !compact
    (button.cell as? NSPopUpButtonCell)?.arrowPosition = compact ? .noArrow : .arrowAtBottom
    button.toolTip = accessibilityLabel
    button.isEnabled = isEnabled && items.contains {
      if case .option(let option) = $0 { return option.enabled }
      return false
    }
    button.font = appearance.nativeFont(size: 13)
    button.contentTintColor = NSColor(appearance.foregroundColor)
    button.setAccessibilityLabel(accessibilityLabel)
    button.setAccessibilityValue(title)
    if coordinator.items != items || button.numberOfItems == 0 {
      button.removeAllItems()
      coordinator.values.removeAll()
      button.addItem(withTitle: title)
      for item in items {
        switch item {
        case .section(let title): button.menu?.addItem(.sectionHeader(title: title))
        case .separator: button.menu?.addItem(.separator())
        case .option(let option):
          let native = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
          native.state = option.selected ? .on : .off
          native.isEnabled = option.enabled
          native.toolTip = option.help
          native.image = option.systemImage.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
          button.menu?.addItem(native)
          coordinator.values[ObjectIdentifier(native)] = option.value
        }
      }
      coordinator.items = items
    }
    button.item(at: 0)?.title = title
    button.item(at: 0)?.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
    button.invalidateIntrinsicContentSize()
  }

  static func dismantleNSView(_ button: SettingsMenuControl, coordinator: Coordinator) {
    coordinator.active = false
    coordinator.values.removeAll()
    button.active = false
    button.target = nil
  }

  final class Coordinator: NSObject {
    var parent: SettingsDropdownMenu
    var items: [SettingsDropdownItem<Value>] = []
    var values: [ObjectIdentifier: Value] = [:]
    var active = true
    init(_ parent: SettingsDropdownMenu) { self.parent = parent }

    @objc func selected(_ button: SettingsMenuControl) {
      guard active, parent.isEnabled, button.acceptsFirstResponder,
        let item = button.selectedItem, item.isEnabled,
        let value = values[ObjectIdentifier(item)] else { return }
      parent.onSelect(value)
    }
  }
}
