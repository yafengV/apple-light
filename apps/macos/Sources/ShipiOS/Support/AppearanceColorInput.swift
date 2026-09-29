import AppKit
import CoreText
import SwiftUI

struct AppearanceColorInput: NSViewRepresentable {
  let value: String
  let label: String
  var available: () -> Bool = { true }
  let onChange: (String) -> Bool
  @Environment(\.isEnabled) private var enabled
  @Environment(\.appAppearance) private var appearance
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> Control {
    let view = Control(); view.owner = context.coordinator; view.field.delegate = context.coordinator
    view.swatch.target = context.coordinator; view.swatch.action = #selector(Coordinator.clicked(_:))
    return view
  }
  func updateNSView(_ view: Control, context: Context) {
    let owner = context.coordinator; owner.parent = self
    let canEdit = enabled && available()
    view.field.isEnabled = canEdit; view.field.isEditable = canEdit; view.field.isSelectable = canEdit; view.swatch.isEnabled = canEdit
    let font = appearance.nativeFont(size: 12)
    view.field.font = NSFont(descriptor: font.fontDescriptor.addingAttributes([.featureSettings: [[
      NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
      NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector
    ]]]), size: font.pointSize) ?? font
    view.field.setAccessibilityLabel(label); view.swatch.setAccessibilityLabel(label + "选色面板")
    view.setAccessibilityLabel(label); view.swatch.setAccessibilityExpanded(owner.popup != nil)
    owner.receive(value, in: view); owner.schedule(view)
  }
  static func dismantleNSView(_ view: Control, coordinator: Coordinator) {
    coordinator.active = false; coordinator.detach(); view.active = false; view.owner = nil; view.field.delegate = nil; view.swatch.target = nil
  }
  static func placement(anchor: CGRect, viewport: CGRect) -> CGRect? {
    let available = viewport.insetBy(dx: 6, dy: 6), size: CGFloat = 224
    guard anchor.intersects(available), available.width >= size, available.height >= size else { return nil }
    let below = anchor.minY - 8 - available.minY, above = available.maxY - anchor.maxY - 8
    let preferredY = below >= size || below >= above ? anchor.minY - 8 - size : anchor.maxY + 8
    return .init(x: max(available.minX, min(anchor.maxX - size, available.maxX - size)),
      y: max(available.minY, min(preferredY, available.maxY - size)), width: size, height: size)
  }
  final class Control: NSView {
    weak var owner: Coordinator?
    var active = true
    var color = AppearanceRGBA.black { didSet { needsDisplay = true; swatch.needsDisplay = true } }
    let field = Field(), swatch = Swatch()
    override var intrinsicContentSize: NSSize { .init(width: 136, height: 28) }
    override init(frame: NSRect) {
      super.init(frame: frame); addSubview(swatch); addSubview(field); swatch.container = self; field.container = self
      field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
      field.cell = Cell(textCell: ""); field.cell?.usesSingleLineMode = true; field.cell?.isScrollable = true
      swatch.isBordered = false; swatch.setAccessibilityRole(.popUpButton)
    }
    convenience init() { self.init(frame: .init(x: 0, y: 0, width: 136, height: 28)) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
      super.layout(); swatch.frame = .init(x: 8, y: (bounds.height - 14) / 2, width: 14, height: 14)
      field.frame = .init(x: 30, y: 0, width: max(0, bounds.width - 38), height: bounds.height); owner?.schedule(self)
    }
    override func draw(_ dirtyRect: NSRect) {
      color.nativeColor.withAlphaComponent(field.isEnabled ? 1 : 0.5).setFill()
      NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); owner?.attach(self) }
  }
  final class Cell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
      let height = ceil(font.map { NSLayoutManager().defaultLineHeight(for: $0) } ?? 16)
      return .init(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
    }
    override func edit(withFrame rect: NSRect, in view: NSView, editor: NSText, delegate: Any?, event: NSEvent?) { super.edit(withFrame: drawingRect(forBounds: rect), in: view, editor: editor, delegate: delegate, event: event) }
    override func select(withFrame rect: NSRect, in view: NSView, editor: NSText, delegate: Any?, start: Int, length: Int) { super.select(withFrame: drawingRect(forBounds: rect), in: view, editor: editor, delegate: delegate, start: start, length: length) }
  }
  final class Field: NSTextField {
    weak var container: Control?
    override var acceptsFirstResponder: Bool { container?.active == true && isEnabled && !isHiddenOrHasHiddenAncestor }
    override var canBecomeKeyView: Bool { acceptsFirstResponder && window != nil }
  }
  final class Swatch: NSButton {
    weak var container: Control?
    override var acceptsFirstResponder: Bool { container?.active == true && isEnabled && !isHiddenOrHasHiddenAncestor }
    override var canBecomeKeyView: Bool { acceptsFirstResponder && window != nil }
    override func draw(_ dirtyRect: NSRect) {
      guard let color = container?.color else { return }
      let path = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)); color.nativeColor.setFill(); path.fill()
      let ink = AppearanceColorEditing.readableInk(color.hex)
      NSColor(srgbRed: (Double(color.red) * 0.82 + Double(ink.red) * 0.18) / 255,
        green: (Double(color.green) * 0.82 + Double(ink.green) * 0.18) / 255,
        blue: (Double(color.blue) * 0.82 + Double(ink.blue) * 0.18) / 255, alpha: 1).setStroke(); path.lineWidth = 1; path.stroke()
    }
    override func mouseDown(with event: NSEvent) { guard acceptsFirstResponder else { return }; window?.makeFirstResponder(self); super.mouseDown(with: event) }
    override func keyDown(with event: NSEvent) {
      if acceptsFirstResponder, [36, 49, 76].contains(event.keyCode), event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
        if !event.isARepeat { container?.owner?.toggle(container!) }; return
      }
      super.keyDown(with: event)
    }
    override func accessibilityPerformPress() -> Bool { guard acceptsFirstResponder, let container else { return false }; container.owner?.toggle(container); return true }
  }
  @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: AppearanceColorInput
    var active = true
    private(set) var draft: String?
    private(set) var value = ""
    private(set) var hsv = AppearanceHSV(hex: "#000000")
    private(set) var popup: SettingsPopupMenuButton.HostingView?
    private var token = UUID(), focusToken = UUID()
    private var scheduled = false
    private var observers: [NSObjectProtocol] = []
    private var monitor: Any?
    private weak var observedWindow: NSWindow?
    init(_ parent: AppearanceColorInput) { self.parent = parent }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) }; if let monitor { NSEvent.removeMonitor(monitor) } }
    private func canAct(_ view: Control) -> Bool { active && parent.enabled && parent.available() && view.active && view.window != nil && view.field.acceptsFirstResponder && view.window?.attachedSheet == nil }
    func receive(_ hex: String, in view: Control) {
      let incoming = hex.uppercased()
      if incoming != value { value = incoming; hsv = .init(hex: incoming) }
      view.color = .init(hex: incoming); view.field.textColor = AppearanceColorEditing.readableInk(incoming).nativeColor
      if draft == nil, (view.field.currentEditor() as? NSTextView)?.hasMarkedText() != true { replace(view.field, text: value) }
    }
    private func replace(_ field: Field, text: String) {
      guard field.stringValue != text || field.currentEditor().map({ $0.string != text }) == true else { return }
      field.stringValue = text
      if let editor = field.currentEditor() as? NSTextView { editor.string = text; editor.setSelectedRange(.init(location: text.utf16.count, length: 0)) }
    }
    private func apply(_ hex: String, in view: Control, fromPicker: Bool) {
      guard canAct(view) else { return }
      draft = nil
      if parent.onChange(hex) {
        value = hex.uppercased(); if !fromPicker { hsv = .init(hex: value) }
      } else { hsv = .init(hex: value) }
      view.color = .init(hex: value); view.field.textColor = AppearanceColorEditing.readableInk(value).nativeColor
      replace(view.field, text: value); update(view)
    }
    func controlTextDidBeginEditing(_ notification: Notification) {
      guard let field = notification.object as? Field, let editor = field.currentEditor() as? NSTextView else { return }
      editor.isAutomaticSpellingCorrectionEnabled = false; editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
    }
    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? Field, let view = field.container, canAct(view),
        (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
      let text = AppearanceColorEditing.sanitized(field.currentEditor()?.string ?? field.stringValue)
      if let parsed = AppearanceColorEditing.parsed(text) { apply(parsed, in: view, fromPicker: false) }
      else { draft = text; replace(field, text: text) }
    }
    func controlTextDidEndEditing(_ notification: Notification) {
      guard let field = notification.object as? Field, let view = field.container else { return }
      draft = nil; replace(field, text: value); view.needsDisplay = true
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      guard let field = control as? Field, let view = field.container, canAct(view), !textView.hasMarkedText() else { return false }
      return selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.cancelOperation(_:))
    }
    @objc func clicked(_ button: Swatch) { if let view = button.container { toggle(view) } }
    func toggle(_ view: Control) {
      guard canAct(view), view.swatch.acceptsFirstResponder else { return }
      focusToken = UUID()
      if popup != nil { dismiss(view, restore: true); return }
      view.window?.makeFirstResponder(view.swatch)
      view.window?.contentView?.subviews.compactMap { $0 as? SettingsPopupMenuButton.HostingView }.forEach { $0.dismissMenu?() }
      token = UUID(); open(view)
    }
    private func open(_ view: Control) {
      guard canAct(view), let window = view.window, let content = window.contentView,
        let frame = AppearanceColorInput.placement(anchor: view.swatch.convert(view.swatch.bounds, to: nil), viewport: content.convert(content.bounds, to: nil)) else { return }
      let host = SettingsPopupMenuButton.HostingView(rootView: root(view)); host.sizingOptions = []; host.focusRingType = .none
      host.frame = content.convert(frame, from: nil); host.dismissMenu = { [weak self, weak view] in if let view { self?.dismiss(view, restore: false) } }
      content.addSubview(host, positioned: .above, relativeTo: nil); popup = host; view.swatch.setAccessibilityExpanded(true)
    }
    private func root(_ view: Control) -> AnyView {
      let token = token
      return AnyView(AppearanceColorPickerCanvas(value: hsv) { [weak self, weak view] hsv in
        guard let self, let view, self.token == token, self.popup != nil, self.canAct(view) else { return }
        self.hsv = hsv
        if hsv.color.hex.caseInsensitiveCompare(self.value) != .orderedSame { self.apply(hsv.color.hex, in: view, fromPicker: true) }
      }.frame(width: 200, height: 200).padding(12)
        .background(parent.appearance.resolvedColors["controlBackgroundOpaque"].color.opacity(0.9), in: RoundedRectangle(cornerRadius: 12))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(parent.appearance.resolvedColors["border"].color, lineWidth: 0.5))
        .environment(\.appAppearance, parent.appearance).accessibilityLabel(parent.label + "选色面板"))
    }
    func dismiss(_ view: Control, restore: Bool) {
      token = UUID(); popup?.removeFromSuperview(); popup = nil; draft = nil; replace(view.field, text: value); view.swatch.setAccessibilityExpanded(false)
      focusToken = UUID(); let focus = focusToken
      if restore { DispatchQueue.main.async { [weak self, weak view] in
        guard let self, let view, self.focusToken == focus, self.popup == nil, self.canAct(view), view.swatch.acceptsFirstResponder else { return }
        view.window?.makeFirstResponder(view.swatch)
      } }
    }
    func detach() {
      token = UUID(); focusToken = UUID(); popup?.removeFromSuperview(); popup = nil; draft = nil
      observers.forEach { NotificationCenter.default.removeObserver($0) }; observers = []
      if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil; observedWindow = nil
    }
    func attach(_ view: Control) {
      guard view.window !== observedWindow else { return }; detach()
      guard active, let window = view.window else { return }; observedWindow = window
      var ancestor: NSView? = view
      while let current = ancestor {
        current.postsBoundsChangedNotifications = true; current.postsFrameChangedNotifications = true
        for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
          observers.append(NotificationCenter.default.addObserver(forName: name, object: current, queue: .main) { [weak self, weak view] _ in MainActor.assumeIsolated { if let view { self?.schedule(view) } } })
        }
        ancestor = current.superview
      }
      for name in [NSWindow.didResizeNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification, NSWindow.didUpdateNotification] {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self, weak view] note in
          MainActor.assumeIsolated {
            guard let self, let view else { return }
            if note.name == NSWindow.didResizeNotification { self.schedule(view) }
            else if note.name == NSWindow.didUpdateNotification {
              guard self.canAct(view) else { self.dismiss(view, restore: false); return }
              if let popup = self.popup, let first = view.window?.firstResponder as? NSView, first !== view.swatch,
                !first.isDescendant(of: popup) { self.dismiss(view, restore: false) }
            } else { self.dismiss(view, restore: false) }
          }
        })
      }
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self, weak view] event in
        let handled = MainActor.assumeIsolated {
          guard let self, let view, event.window === view.window, view.window?.isKeyWindow == true else { return false }
          return self.handle(event, in: view)
        }
        return handled ? nil : event
      }
    }
    func handle(_ event: NSEvent, in view: Control) -> Bool {
      guard let popup, active else { return false }
      if event.type != .keyDown {
        if !popup.convert(popup.bounds, to: nil).contains(event.locationInWindow), !view.swatch.convert(view.swatch.bounds, to: nil).contains(event.locationInWindow) { dismiss(view, restore: false) }
        return false
      }
      guard event.keyCode == 53, (view.window?.firstResponder as? NSTextView)?.hasMarkedText() != true else { return false }
      dismiss(view, restore: true); return true
    }
    func schedule(_ view: Control) {
      guard active, !scheduled else { return }; scheduled = true
      DispatchQueue.main.async { [weak self, weak view] in guard let self else { return }; self.scheduled = false; if let view { self.update(view) } }
    }
    private func update(_ view: Control) {
      guard active else { return }
      if view.window !== observedWindow { attach(view); return }
      guard let popup else { return }
      guard canAct(view), !view.visibleRect.isEmpty, let content = view.window?.contentView,
        let frame = AppearanceColorInput.placement(anchor: view.swatch.convert(view.swatch.bounds, to: nil), viewport: content.convert(content.bounds, to: nil)) else { dismiss(view, restore: false); return }
      popup.rootView = root(view); let converted = content.convert(frame, from: nil); if popup.frame != converted { popup.frame = converted }
    }
  }
}
