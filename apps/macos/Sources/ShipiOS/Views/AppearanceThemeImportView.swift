import AppKit
import SwiftUI

/// One window-local modal. The store owns its draft and persistence; AppKit
/// supplies the single-line editor and native control focus without a sheet.
struct AppearanceThemeImportView: NSViewRepresentable {
  @Bindable var store: WorkspaceStore
  @Bindable var session: AppearanceThemeImportSession
  @Environment(\.appAppearance) private var appearance
  @Environment(\.colorScheme) private var colorScheme
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> Surface {
    let view = Surface(); view.owner = context.coordinator; context.coordinator.attach(view); return view
  }
  func updateNSView(_ view: Surface, context: Context) {
    let owner = context.coordinator; owner.parent = self
    var resolved = appearance; if resolved.theme == "system" { resolved.theme = colorScheme == .dark ? "dark" : "light" }
    view.colors = resolved.resolvedColors
    view.label.font = NSFont(descriptor: appearance.nativeFont(size: 20).fontDescriptor.addingAttributes(
      [.traits: [NSFontDescriptor.TraitKey.weight: NSFont.Weight.semibold.rawValue]]), size: 0)
    view.label.textColor = view.colors["textForeground"].nativeColor
    view.field.font = NSFont(descriptor: appearance.nativeFont(size: 13, code: true).fontDescriptor,
      size: appearance.nativeFont(size: 13).pointSize)
    view.field.textColor = view.colors["textForeground"].nativeColor
    view.field.placeholderAttributedString = NSAttributedString(string: (try? appearance.themeShare(dark: session.dark).encoded()) ?? "",
      attributes: [.font: view.field.font!, .foregroundColor: view.colors["textForegroundTertiary"].nativeColor])
    view.field.setAccessibilityLabel(session.variantLabel + " 主题分享字符串")
    if view.field.stringValue != session.value, (view.field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
      view.field.stringValue = session.value
    }
    let enabled = store.canEditAppearanceImport(session)
    view.field.isEnabled = enabled; view.field.isEditable = enabled; view.field.isSelectable = enabled
    for button in [view.cancel, view.submit, view.close] {
      button.preferences = resolved; button.font = appearance.nativeFont(size: 13)
      button.isEnabled = button !== view.submit || (enabled && session.valid); button.needsDisplay = true
    }
    view.needsLayout = true; view.needsDisplay = true; owner.scheduleFocus(view)
  }
  static func dismantleNSView(_ view: Surface, coordinator: Coordinator) {
    coordinator.stop(view); view.active = false; view.owner = nil; view.field.delegate = nil
    for button in [view.cancel, view.submit, view.close] { button.active = false; button.activate = nil }
  }
  final class Input: NSTextField {
    weak var surface: Surface?
    override var acceptsFirstResponder: Bool { surface?.active == true && isEnabled && !isHiddenOrHasHiddenAncestor }
    override var canBecomeKeyView: Bool { acceptsFirstResponder && window != nil }
    override func becomeFirstResponder() -> Bool {
      surface?.needsDisplay = true; let result = super.becomeFirstResponder()
      if let editor = currentEditor() as? NSTextView {
        editor.isContinuousSpellCheckingEnabled = false; editor.isGrammarCheckingEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false
        editor.allowsUndo = true
      }
      return result
    }
    override func resignFirstResponder() -> Bool { surface?.needsDisplay = true; return super.resignFirstResponder() }
  }
  final class Surface: NSView {
    weak var owner: Coordinator?
    var active = true
    var colors = AppearancePreferences().resolvedColors
    let panel = NSView(), material = NSVisualEffectView()
    let decoration = Decoration()
    let label = NSTextField(labelWithString: "导入主题"), field = Input()
    let cancel = AppearanceActionButton.Control(), submit = AppearanceActionButton.Control(), close = AppearanceActionButton.Control()
    var dialogFrame: NSRect { .init(x: (bounds.width - min(520, bounds.width * 0.92)) / 2, y: (bounds.height - 156) / 2, width: min(520, bounds.width * 0.92), height: 156) }
    override var isFlipped: Bool { true }
    override func accessibilityFrame() -> NSRect {
      guard let window else { return .zero }
      return window.convertToScreen(convert(dialogFrame, to: nil))
    }
    override init(frame: NSRect) {
      super.init(frame: frame); setAccessibilityRole(.group); setAccessibilitySubrole(.dialog)
      setAccessibilityLabel("导入主题"); setAccessibilityIdentifier("appearance-theme-import-dialog"); setAccessibilityModal(true)
      panel.wantsLayer = true; panel.layer?.cornerRadius = 24; panel.layer?.masksToBounds = true
      material.material = .popover; material.blendingMode = .withinWindow; material.state = .active
      addSubview(panel); panel.addSubview(material)
      decoration.surface = self; addSubview(decoration)
      field.surface = self; field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
      field.cell?.wraps = false; field.cell?.isScrollable = true; field.usesSingleLineMode = true
      label.setAccessibilityElement(false)
      cancel.title = "取消"; submit.title = "导入主题"; submit.primary = true; close.closeIcon = true
      close.setAccessibilityLabel("关闭对话框")
      for view in [label, field, cancel, submit, close] { addSubview(view) }
      setAccessibilityChildren([field, cancel, submit, close])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window != nil { owner?.scheduleFocus(self) } }
    override func layout() {
      super.layout(); let rect = dialogFrame; panel.frame = rect; material.frame = panel.bounds; decoration.frame = bounds
      label.frame = .init(x: rect.minX + 20, y: rect.minY + 20, width: rect.width - 70, height: 28)
      let input = NSRect(x: rect.minX + 20, y: rect.minY + 60, width: rect.width - 40, height: 36)
      let height = min(28, ceil((field.font?.ascender ?? 10) - (field.font?.descender ?? -3) + 3))
      field.frame = .init(x: input.minX + 10, y: input.midY - height / 2, width: input.width - 20, height: height)
      submit.frame = .init(x: input.maxX - submit.intrinsicContentSize.width, y: rect.minY + 108, width: submit.intrinsicContentSize.width, height: 28)
      cancel.frame = .init(x: submit.frame.minX - 8 - cancel.intrinsicContentSize.width, y: rect.minY + 108, width: cancel.intrinsicContentSize.width, height: 28)
      close.frame = .init(x: rect.maxX - 38, y: rect.minY + 16, width: 22, height: 22)
      decoration.needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
      NSColor.black.withAlphaComponent(34 / 255).setFill(); bounds.fill()
      let path = NSBezierPath(roundedRect: dialogFrame, xRadius: 24, yRadius: 24)
      NSGraphicsContext.saveGraphicsState()
      let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.15); shadow.shadowBlurRadius = 20; shadow.shadowOffset = .init(width: 0, height: -8); shadow.set()
      colors["elevatedSecondary"].opacity(0.9).nativeColor.setFill(); path.fill(); NSGraphicsContext.restoreGraphicsState()
    }
    func drawDecoration() {
      let rect = dialogFrame, path = NSBezierPath(roundedRect: dialogFrame, xRadius: 24, yRadius: 24)
      colors["elevatedSecondary"].opacity(0.9).nativeColor.setFill(); path.fill()
      colors["border"].nativeColor.setStroke(); path.lineWidth = 0.5; path.stroke()
      let input = NSRect(x: rect.minX + 20, y: rect.minY + 60, width: rect.width - 40, height: 36)
      let inputPath = NSBezierPath(roundedRect: input.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
      colors["controlBackground"].nativeColor.setFill(); inputPath.fill()
      colors[field.currentEditor() != nil ? "borderFocus" : "borderHeavy"].nativeColor.setStroke(); inputPath.lineWidth = 1; inputPath.stroke()
    }
    override func mouseDown(with event: NSEvent) {
      let point = convert(event.locationInWindow, from: nil)
      if !dialogFrame.contains(point) { owner?.dismiss(self) }
      else if point.y >= dialogFrame.minY + 60, point.y <= dialogFrame.minY + 96 { window?.makeFirstResponder(field) }
    }
  }
  final class Decoration: NSView {
    weak var surface: Surface?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { surface?.drawDecoration() }
  }
  @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: AppearanceThemeImportView
    var active = true, focused = false
    private var monitor: Any?
    init(_ parent: AppearanceThemeImportView) { self.parent = parent }
    func attach(_ view: Surface) {
      view.field.delegate = self
      view.cancel.activate = { [weak self, weak view] in if let view { self?.dismiss(view) } }
      view.close.activate = view.cancel.activate
      view.submit.activate = { [weak self, weak view] in
        guard let self, let view, self.canAct(view), self.parent.session.valid else { return }
        _ = self.parent.store.submitAppearanceImport(self.parent.session)
      }
      for button in [view.cancel, view.submit, view.close] { button.canAct = { [weak self, weak view] in self?.canDismiss(view) == true } }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak view] event in
        let handled = MainActor.assumeIsolated {
          guard let self, let view, let window = view.window, window.isKeyWindow, event.window === window else { return false }
          return self.handle(event, in: view)
        }
        return handled ? nil : event
      }
    }
    func canDismiss(_ view: Surface?) -> Bool {
      guard let view else { return false }
      return active && view.active && view.window != nil && view.window?.attachedSheet == nil
        && parent.store.appearanceThemeImport === parent.session
        && parent.store.destination == .settings && parent.store.settingsPage == .appearance
    }
    func canAct(_ view: Surface) -> Bool { canDismiss(view) && parent.store.canEditAppearanceImport(parent.session) }
    func dismiss(_ view: Surface) { guard canDismiss(view) else { return }; parent.store.dismissAppearanceImport(parent.session) }
    func scheduleFocus(_ view: Surface) {
      guard !focused else { return }
      DispatchQueue.main.async { [weak self, weak view] in
        guard let self, let view, !self.focused, self.canAct(view) else { return }
        self.focused = view.window?.makeFirstResponder(view.field) == true
      }
    }
    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? Input, let view = field.surface, canAct(view) else { return }
      parent.session.value = field.stringValue; view.submit.isEnabled = parent.session.valid; view.submit.needsDisplay = true
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      // This input is not a form: Return does not submit or dismiss.
      !textView.hasMarkedText() && selector == #selector(NSResponder.insertNewline(_:))
    }
    func handle(_ event: NSEvent, in view: Surface) -> Bool {
      guard canDismiss(view) else { return false }
      let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
      let editor = view.window?.firstResponder as? NSTextView
      if editor?.hasMarkedText() == true { return false }
      if event.keyCode == 53, flags.isEmpty { dismiss(view); return true }
      if event.keyCode == 48, flags.isEmpty || flags == .shift {
        let controls: [NSView] = [view.field, view.cancel, view.submit, view.close].filter { $0.acceptsFirstResponder }
        guard !controls.isEmpty else { return true }
        let current = view.window?.firstResponder
        let index = controls.firstIndex { $0 === current || ($0 === view.field && editor?.delegate as AnyObject? === view.field) }
        let next = index.map { ($0 + (flags == .shift ? -1 : 1) + controls.count) % controls.count } ?? (flags == .shift ? controls.count - 1 : 0)
        view.window?.makeFirstResponder(controls[next]); return true
      }
      if flags.isEmpty, [36, 76].contains(event.keyCode), editor?.delegate as AnyObject? === view.field { return true }
      return false
    }
    func stop(_ view: Surface) {
      active = false; if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
      let current = view.window?.firstResponder
      let editor = current as? NSTextView
      if current === view.field || editor?.delegate as AnyObject? === view.field
        || [view.cancel, view.submit, view.close].contains(where: { current === $0 }) {
        view.window?.makeFirstResponder(nil)
      }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
  }
}
