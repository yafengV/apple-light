import AppKit
import SwiftUI

struct SettingsMenuOption<Value: Hashable>: Equatable {
  let value: Value
  let title: String
  var enabled = true
  var swatch: SettingsMenuSwatch? = nil
}

struct SettingsMenuSwatch: Equatable {
  let accent: String
  let foreground: String
  let background: String
  @MainActor func image(appearance: AppearancePreferences) -> NSImage? {
    ImageRenderer(content: ThemeColorSwatch(swatch: self).environment(\.appAppearance, appearance)).nsImage
  }
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
        .settingsFocusReveal()
        .fixedSize(horizontal: false, vertical: true)
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
  @Environment(\.settingsNativeControlDidFocus) private var didFocus
  @Environment(\.layoutDirection) private var direction
  let title: String
  @Binding var selection: Value
  let options: [SettingsMenuOption<Value>]

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> SettingsMenuControl {
    let button = SettingsMenuControl(frame: .zero, pullsDown: false)
    button.target = context.coordinator
    button.action = #selector(Coordinator.changed(_:))
    button.menu?.autoenablesItems = false
    button.menu?.delegate = context.coordinator
    context.coordinator.button = button
    (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
    button.setAccessibilityLabel(title)
    return button
  }

  func updateNSView(_ button: SettingsMenuControl, context: Context) {
    let coordinator = context.coordinator
    coordinator.parent = self
    button.didFocus = didFocus
    button.isEnabled = isEnabled && options.contains(where: \.enabled)
    button.font = appearance.nativeFont(size: 13)
    button.contentTintColor = NSColor(appearance.foregroundColor)
    button.setAccessibilityLabel(title)
    if coordinator.options != options {
      button.removeAllItems()
      for option in options {
        let item = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
        item.isEnabled = option.enabled
        item.image = option.swatch?.image(appearance: appearance)
        button.menu?.addItem(item)
      }
      coordinator.options = options
    }
    button.selectItem(at: options.firstIndex(where: { $0.value == selection }) ?? -1)
    button.formTrigger = .init(appearance: appearance,
      swatch: options.first(where: { $0.value == selection })?.swatch, direction: direction)
    button.invalidateIntrinsicContentSize()
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: SettingsMenuControl, context: Context) -> CGSize? {
    let ideal = nsView.intrinsicContentSize
    return .init(width: max(0, min(ideal.width, proposal.width ?? ideal.width)), height: ideal.height)
  }

  static func dismantleNSView(_ button: SettingsMenuControl, coordinator: Coordinator) {
    coordinator.active = false
    button.active = false
    button.didFocus = nil
    button.menu?.delegate = nil
    coordinator.button = nil
    button.formTrigger = nil
    button.target = nil
  }

  final class Coordinator: NSObject, NSMenuDelegate {
    weak var button: SettingsMenuControl?
    var parent: SettingsMenuInput
    var options: [SettingsMenuOption<Value>] = []
    var active = true
    init(_ parent: SettingsMenuInput) { self.parent = parent }

    func menuWillOpen(_ menu: NSMenu) {
      guard active, let button, button.menu === menu else { return }
      button.formMenuOpen = true
    }
    func menuDidClose(_ menu: NSMenu) {
      guard let button, button.menu === menu else { return }
      button.formMenuOpen = false
    }

    @objc func changed(_ button: SettingsMenuControl) {
      let index = button.indexOfSelectedItem
      guard active, button.active, parent.isEnabled, button.isEnabled,
        !button.isHiddenOrHasHiddenAncestor,
        options.indices.contains(index), options[index].enabled else { return }
      let value = options[index].value
      if parent.selection != value { parent.selection = value }
      // A rejected binding write leaves the model unchanged. Restore the
      // actual popup too, even when the surrounding form retains its identity.
      button.selectItem(at: options.firstIndex(where: { $0.value == parent.selection }) ?? -1)
    }
  }
}

final class SettingsMenuControl: NSPopUpButton {
  var formTrigger: SettingsMenuTriggerConfiguration? { didSet { updateFormSurface(); invalidateIntrinsicContentSize() } }
  var formMenuOpen = false { didSet { updateFormSurface() } }
  private var formHovered = false
  private var formFocused = false
  private var pointerFocus = false
  private var formHost: SettingsMenuTriggerHostingView?
  private var formTrackingArea: NSTrackingArea?

  override var intrinsicContentSize: NSSize {
    guard let formTrigger else { return super.intrinsicContentSize }
    let textWidth = ((titleOfSelectedItem ?? "") as NSString).size(withAttributes:
      [.font: formTrigger.appearance.nativeFont(size: SettingsMenuTriggerMetrics.fontSize)]).width
    let leading = formTrigger.swatch == nil ? SettingsMenuTriggerMetrics.padding
      : SettingsMenuTriggerMetrics.swatchPadding + SettingsMenuTriggerMetrics.swatchSize + SettingsMenuTriggerMetrics.swatchGap
    return .init(width: ceil(textWidth + leading + SettingsMenuTriggerMetrics.padding
      + 2 * SettingsMenuTriggerMetrics.border + SettingsMenuTriggerMetrics.gap + SettingsMenuTriggerMetrics.chevronSize),
      height: SettingsMenuTriggerMetrics.height)
  }

  override func layout() {
    super.layout()
    formHost?.frame = bounds.insetBy(dx: -SettingsMenuTriggerMetrics.focusRing, dy: -SettingsMenuTriggerMetrics.focusRing)
  }
  override func draw(_ dirtyRect: NSRect) {
    if formTrigger == nil { super.draw(dirtyRect) }
  }
  override func selectItem(at index: Int) {
    super.selectItem(at: index)
    updateFormSurface()
  }
  private func updateFormSurface() {
    guard let formTrigger else {
      formHost?.removeFromSuperview(); formHost = nil
      return
    }
    isTransparent = true; focusRingType = .none
    let view = AnyView(SettingsMenuTriggerSurface(title: titleOfSelectedItem ?? "", swatch: formTrigger.swatch,
      hovered: formHovered, open: formMenuOpen, focused: formFocused)
      .disabled(!isEnabled).padding(SettingsMenuTriggerMetrics.focusRing)
      .environment(\.appAppearance, formTrigger.appearance).environment(\.layoutDirection, formTrigger.direction))
    if let formHost { formHost.rootView = view }
    else {
      let host = SettingsMenuTriggerHostingView(rootView: view)
      host.setAccessibilityElement(false); addSubview(host); formHost = host
    }
    needsLayout = true; needsDisplay = true
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let formTrackingArea { removeTrackingArea(formTrackingArea); self.formTrackingArea = nil }
    if formTrigger != nil {
      let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
      addTrackingArea(area); formTrackingArea = area
    }
  }
  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event); formHovered = true; updateFormSurface()
  }
  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event); formHovered = false; updateFormSurface()
  }
  override func resignFirstResponder() -> Bool {
    let accepted = super.resignFirstResponder()
    if accepted { formFocused = false; updateFormSurface() }
    return accepted
  }

  var didFocus: (() -> Void)?
  var active = true { didSet { releaseDisabledFocus() } }
  private var requestedEnabled = true
  private var enabledGeneration = UUID()
  override var isEnabled: Bool {
    get { requestedEnabled }
    set {
      guard requestedEnabled != newValue else { return }
      requestedEnabled = newValue
      updateFormSurface()
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

  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted {
      formFocused = !pointerFocus; updateFormSurface()
      DispatchQueue.main.async { [weak self] in
        guard let self, self.acceptsFirstResponder,
          self.window?.firstResponder === self else { return }
        self.didFocus?()
      }
    }
    return accepted
  }

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

  override func drawFocusRingMask() {
    if isTransparent { NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill() }
    else { super.drawFocusRingMask() }
  }
  override var focusRingMaskBounds: NSRect { isTransparent ? bounds : super.focusRingMaskBounds }

  override func mouseDown(with event: NSEvent) {
    guard acceptsFirstResponder else { return }
    pointerFocus = true
    window?.makeFirstResponder(self)
    pointerFocus = false; formFocused = false; updateFormSurface()
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
      formFocused = true; updateFormSurface()
      if !event.isARepeat { performClick(nil) }
      return
    }
    super.keyDown(with: event)
  }
}
