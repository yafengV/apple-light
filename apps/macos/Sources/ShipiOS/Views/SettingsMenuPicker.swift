import AppKit
import SwiftUI

struct SettingsMenuOption<Value: Hashable>: Equatable {
  let value: Value
  let title: String
  var enabled = true
}

/// A settings menu whose actual popup, rather than an inert SwiftUI wrapper,
/// owns keyboard focus and native menu tracking.
struct SettingsMenuPicker<Value: Hashable>: View {
  let title: String
  let description: String?
  @Binding var selection: Value
  let options: [SettingsMenuOption<Value>]

  init(_ title: String, description: String? = nil, selection: Binding<Value>, options: [SettingsMenuOption<Value>]) {
    self.title = title
    self.description = description
    _selection = selection
    self.options = options
  }

  var body: some View {
    LabeledContent {
      SettingsMenuInput(title: title, selection: $selection, options: options)
        .fixedSize(horizontal: true, vertical: true)
        .alignmentGuide(.firstTextBaseline) { dimensions in
          description == nil ? dimensions[.firstTextBaseline] : dimensions[VerticalAlignment.center]
        }
    } label: {
      SettingsControlLabel(title: title, description: description)
    }
  }
}

struct SettingsMenuInput<Value: Hashable>: NSViewRepresentable {
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.appAppearance) private var appearance
  let title: String
  @Binding var selection: Value
  let options: [SettingsMenuOption<Value>]

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> SettingsMenuControl {
    let button = SettingsMenuControl(frame: .zero, pullsDown: false)
    button.target = context.coordinator
    button.action = #selector(Coordinator.changed(_:))
    button.menu?.autoenablesItems = false
    button.setAccessibilityLabel(title)
    return button
  }

  func updateNSView(_ button: SettingsMenuControl, context: Context) {
    let coordinator = context.coordinator
    coordinator.parent = self
    button.isEnabled = isEnabled && options.contains(where: \.enabled)
    button.font = appearance.nativeFont(size: 13)
    button.contentTintColor = NSColor(appearance.foregroundColor)
    button.setAccessibilityLabel(title)
    if coordinator.options != options {
      button.removeAllItems()
      for option in options {
        let item = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
        item.isEnabled = option.enabled
        button.menu?.addItem(item)
      }
      coordinator.options = options
    }
    button.selectItem(at: options.firstIndex(where: { $0.value == selection }) ?? -1)
    button.invalidateIntrinsicContentSize()
  }

  static func dismantleNSView(_ button: SettingsMenuControl, coordinator: Coordinator) {
    coordinator.active = false
    button.active = false
    button.target = nil
  }

  final class Coordinator: NSObject {
    var parent: SettingsMenuInput
    var options: [SettingsMenuOption<Value>] = []
    var active = true
    init(_ parent: SettingsMenuInput) { self.parent = parent }

    @objc func changed(_ button: SettingsMenuControl) {
      let index = button.indexOfSelectedItem
      guard active, button.active, parent.isEnabled, button.isEnabled,
        !button.isHiddenOrHasHiddenAncestor,
        options.indices.contains(index), options[index].enabled else { return }
      let value = options[index].value
      if parent.selection != value { parent.selection = value }
    }
  }
}

final class SettingsMenuControl: NSPopUpButton {
  var active = true { didSet { releaseDisabledFocus() } }
  private var requestedEnabled = true
  private var enabledGeneration = UUID()
  override var isEnabled: Bool {
    get { requestedEnabled }
    set {
      guard requestedEnabled != newValue else { return }
      requestedEnabled = newValue
      enabledGeneration = UUID()
      let generation = enabledGeneration
      // SwiftUI also sets this property while adopting the environment, before
      // updateNSView. NSCell.setEnabled walks the key loop synchronously, which
      // re-enters NSHostingView's focus graph during that unfinished update.
      // Reject interaction immediately; update the cell after the transaction.
      DispatchQueue.main.async { [weak self] in
        guard let self, self.enabledGeneration == generation else { return }
        self.applyEnabled(newValue)
      }
    }
  }
  override var acceptsFirstResponder: Bool { active && isEnabled && !isHiddenOrHasHiddenAncestor }
  override var canBecomeKeyView: Bool { acceptsFirstResponder && window != nil }

  private func applyEnabled(_ enabled: Bool) {
    if !enabled, let window, window.firstResponder === self { window.makeFirstResponder(nil) }
    super.isEnabled = enabled
  }

  private func releaseDisabledFocus() {
    guard !active || !isEnabled else { return }
    // Let a simultaneous page/navigation focus request finish first. Clearing
    // synchronously can undo SwiftUI's move to the newly selected sidebar item.
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.active || !self.isEnabled,
        let window = self.window, window.firstResponder === self else { return }
      window.makeFirstResponder(nil)
    }
  }

  override func mouseDown(with event: NSEvent) {
    guard acceptsFirstResponder else { return }
    window?.makeFirstResponder(self)
    super.mouseDown(with: event)
  }

  override func accessibilityPerformPress() -> Bool {
    guard acceptsFirstResponder else { return false }
    window?.makeFirstResponder(self)
    return super.accessibilityPerformPress()
  }

  override func keyDown(with event: NSEvent) {
    guard acceptsFirstResponder else { return }
    let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
    if modifiers.isEmpty, [36, 49, 76, 125].contains(event.keyCode) {
      if !event.isARepeat { performClick(nil) }
      return
    }
    super.keyDown(with: event)
  }
}
