import AppKit
import SwiftUI

/// Attach the dialog to the originating window, even when the PR lives in a
/// narrow side pane. No sheet, panel or separate window is created.
struct PullRequestMergeDialogPresenter: NSViewRepresentable {
  @Bindable var state: GitHubPRDetailState
  let request: GitHubPullRequest
  let writable: Bool
  let valid: () -> Bool
  let confirm: () -> Void
  @Environment(\.appAppearance) private var appearance
  @Environment(\.colorScheme) private var colorScheme

  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> Anchor {
    let anchor = Anchor(); anchor.owner = context.coordinator; return anchor
  }
  func updateNSView(_ anchor: Anchor, context: Context) {
    let owner = context.coordinator; owner.parent = self
    var resolved = appearance
    if resolved.theme == "system" { resolved.theme = colorScheme == .dark ? "dark" : "light" }
    owner.preferences = resolved
    // Read observable values while SwiftUI updates this representable.
    let showing = state.showingMergeConfirmation, busy = state.busy(for: request)
    let methods = state.snapshot?.allowedMethods, selected = state.selectedMethod, error = state.error
    let reason = state.mergeDisabledReason(for: request, writable: writable)
    owner.update(anchor, showing: showing, busy: busy, methods: methods, selected: selected, error: error, reason: reason)
  }
  static func dismantleNSView(_ anchor: Anchor, coordinator: Coordinator) {
    anchor.owner = nil; coordinator.stop()
  }
  final class Anchor: NSView {
    weak var owner: Coordinator?
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); owner?.anchorMoved(self) }
  }

  final class Button: NSButton {
    enum Style { case method, secondary, primary, danger }
    var style = Style.secondary
    var selected = false
    var loading = false
    private var tracking: NSTrackingArea?
    private var hovered = false { didSet { needsDisplay = true } }
    var preferences = AppearancePreferences()
    var active = true
    var available: () -> Bool = { false }
    var activate: (() -> Void)?
    override init(frame: NSRect) {
      super.init(frame: frame); isBordered = false; setButtonType(.momentaryPushIn)
      target = self; action = #selector(pressed); focusRingType = .none
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool {
      active && isEnabled && available() && !isHiddenOrHasHiddenAncestor && WindowModalInteraction.allows(self)
    }
    override var canBecomeKeyView: Bool { acceptsFirstResponder && window != nil }
    override var intrinsicContentSize: NSSize { .init(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    @objc private func pressed() { guard acceptsFirstResponder, window != nil else { return }; activate?() }
    override func accessibilityPerformPress() -> Bool {
      guard acceptsFirstResponder, window != nil else { return false }; activate?(); return true
    }
    override func mouseDown(with event: NSEvent) {
      guard acceptsFirstResponder else { return }; window?.makeFirstResponder(self); super.mouseDown(with: event)
    }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }
    override func keyDown(with event: NSEvent) {
      let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
      if flags.isEmpty, [36, 49, 76].contains(event.keyCode) {
        if !event.isARepeat { pressed() }; return
      }
      super.keyDown(with: event)
    }
    override func updateTrackingAreas() {
      super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
      let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
      tracking = area; addTrackingArea(area)
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func resetCursorRects() {
      super.resetCursorRects()
      if preferences.usePointerCursors && acceptsFirstResponder { addCursorRect(bounds, cursor: .pointingHand) }
    }
    override func draw(_ dirtyRect: NSRect) {
      let roles = preferences.resolvedColors, alpha: Double = isEnabled ? 1 : 0.4
      let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
      let feedback = isEnabled && (hovered || isHighlighted)
      let background = style == .primary ? "textForeground" : feedback ? "buttonSecondaryBackgroundHover"
        : style == .method && !selected ? "transparent" : "controlBackground"
      if style == .danger {
        NSColor.systemRed.withAlphaComponent(alpha * (feedback ? 0.8 : 1)).setFill(); path.fill()
      } else if background != "transparent" {
        roles[background].opacity(alpha * (style == .primary && feedback ? 0.8 : 1)).nativeColor.setFill(); path.fill()
      }
      let text = NSAttributedString(string: title, attributes: [.font: font ?? .systemFont(ofSize: 13),
        .foregroundColor: style == .danger ? NSColor.white.withAlphaComponent(alpha) : roles[style == .primary ? "controlBackgroundOpaque" : "textForeground"].opacity(alpha).nativeColor])
      text.draw(at: .init(x: (bounds.width - text.size().width) / 2 + (loading ? 10 : 0), y: (bounds.height - text.size().height) / 2))
      if window?.firstResponder === self {
        roles["borderFocus"].nativeColor.setStroke(); path.lineWidth = 2; path.stroke()
      }
    }
  }

  final class Surface: NSView, WindowModalScope {
    weak var owner: Coordinator?
    var active = true
    var modalRoot: NSView { self }
    var modalScopeActive: Bool { active && owner?.canPresent(in: window) == true }
    var blocksWorkspaceCommands: Bool { true }
    var preferences = AppearancePreferences()
    let title = NSTextField(labelWithString: "合并 Pull Request")
    let subtitle = NSTextField(wrappingLabelWithString: "GitHub 只会在当前显示的头提交仍然匹配时合并。")
    let error = NSTextField(wrappingLabelWithString: "")
    let squash = Button(), merge = Button(), cancel = Button(), submit = Button()
    let progress = NSProgressIndicator()
    let errorScroll = NSScrollView()
    var dialogFrame: NSRect = .zero
    override var isFlipped: Bool { true }
    override func accessibilityFrame() -> NSRect {
      guard let window else { return .zero }
      return window.convertToScreen(convert(dialogFrame, to: nil))
    }
    override init(frame: NSRect) {
      super.init(frame: frame)
      setAccessibilityRole(.group); setAccessibilitySubrole(.dialog); setAccessibilityModal(true)
      setAccessibilityLabel("合并 Pull Request"); setAccessibilityIdentifier("pull-request-merge-dialog")
      title.setAccessibilityElement(false); subtitle.setAccessibilityElement(true)
      squash.title = "压缩"; merge.title = "合并提交"; cancel.title = "取消"
      squash.style = .method; merge.style = .method; submit.style = .primary
      for (button, id) in [(squash, "squash"), (merge, "merge"), (cancel, "cancel"), (submit, "submit")] {
        button.setAccessibilityIdentifier("pull-request-merge-" + id); addSubview(button)
      }
      addSubview(title); addSubview(subtitle)
      error.isSelectable = true; error.setAccessibilityRole(.staticText)
      error.setAccessibilityIdentifier("pull-request-merge-error")
      errorScroll.drawsBackground = false; errorScroll.hasVerticalScroller = true; errorScroll.autohidesScrollers = true
      errorScroll.documentView = error; addSubview(errorScroll)
      progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false
      progress.setAccessibilityElement(false); addSubview(progress)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    var controls: [Button] { [squash, merge, cancel, submit].filter { $0.acceptsFirstResponder } }
    private func textHeight(_ field: NSTextField, width: CGFloat) -> CGFloat {
      max(18, ceil(field.cell?.cellSize(forBounds: .init(x: 0, y: 0, width: width, height: 10_000)).height ?? 18))
    }
    override func layout() {
      super.layout()
      let width = min(520, max(0, bounds.width - 40)), inner = max(0, width - 40)
      let subtitleHeight = textHeight(subtitle, width: inner)
      let showMethods = !squash.isHidden || !merge.isHidden
      let errorHeight = errorScroll.isHidden ? 0 : min(120, textHeight(error, width: max(0, inner - 16)))
      let height = 40 + 28 + 4 + subtitleHeight + (showMethods ? 40 : 0)
        + (errorHeight > 0 ? errorHeight + 12 : 0) + 40
      dialogFrame = .init(x: (bounds.width - width) / 2, y: max(12, (bounds.height - height) / 2), width: width, height: height)
      var y = dialogFrame.minY + 20
      title.frame = .init(x: dialogFrame.minX + 20, y: y, width: inner, height: 28); y += 32
      subtitle.frame = .init(x: title.frame.minX, y: y, width: inner, height: subtitleHeight); y += subtitleHeight
      if showMethods {
        y += 12; let firstWidth: CGFloat = 58, secondWidth: CGFloat = 92
        squash.frame = .init(x: title.frame.minX, y: y, width: firstWidth, height: 28)
        merge.frame = .init(x: squash.isHidden ? title.frame.minX : squash.frame.maxX + 2, y: y, width: secondWidth, height: 28)
        y += 28
      }
      if errorHeight > 0 {
        y += 12; errorScroll.frame = .init(x: title.frame.minX, y: y, width: inner, height: errorHeight)
        error.frame = .init(x: 0, y: 0, width: max(0, inner - 16), height: textHeight(error, width: max(0, inner - 16)))
      }
      let confirmWidth = ceil((submit.title as NSString).size(withAttributes: [.font: submit.font ?? .systemFont(ofSize: 13)]).width) + 28 + (submit.loading ? 24 : 0)
      submit.frame = .init(x: dialogFrame.maxX - 20 - confirmWidth, y: dialogFrame.maxY - 48, width: confirmWidth, height: 28)
      cancel.frame = .init(x: submit.frame.minX - 70, y: submit.frame.minY, width: 62, height: 28)
      progress.frame = .init(x: submit.frame.minX + 8, y: submit.frame.minY + 6, width: 16, height: 16)
      needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
      NSColor.black.withAlphaComponent(0.3).setFill(); bounds.fill()
      NSGraphicsContext.saveGraphicsState()
      let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
      shadow.shadowBlurRadius = 24; shadow.shadowOffset = .init(width: 0, height: -8); shadow.set()
      let path = NSBezierPath(roundedRect: dialogFrame, xRadius: 20, yRadius: 20)
      preferences.resolvedColors["elevatedSecondary"].nativeColor.setFill(); path.fill()
      NSGraphicsContext.restoreGraphicsState()
      preferences.resolvedColors["border"].nativeColor.setStroke(); path.lineWidth = 0.5; path.stroke()
    }
    override func mouseDown(with event: NSEvent) {
      guard !event.modifierFlags.contains(.control), !dialogFrame.contains(convert(event.locationInWindow, from: nil)) else { return }
      owner?.dismiss()
    }
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {
      if !dialogFrame.contains(convert(event.locationInWindow, from: nil)) { owner?.dismiss() }
    }
  }

  @MainActor final class Coordinator {
    var parent: PullRequestMergeDialogPresenter
    var preferences = AppearancePreferences()
    private(set) var surface: Surface?
    private weak var anchor: Anchor?
    private weak var window: NSWindow?
    private weak var returnView: NSView?
    private weak var lastFocused: Button?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var active = true
    private var presentationToken = UUID()
    init(_ parent: PullRequestMergeDialogPresenter) { self.parent = parent }
    func canPresent(in window: NSWindow?) -> Bool {
      active && parent.state.showingMergeConfirmation && parent.valid() && window != nil
        && window?.attachedSheet == nil && self.window === window
    }
    func canAct() -> Bool {
      guard let surface else { return false }
      return surface.active && canPresent(in: surface.window) && WindowModalInteraction.allows(surface)
    }
    func update(_ anchor: Anchor, showing: Bool, busy: Bool, methods: [GitHubPRMergeMethod]?,
      selected: GitHubPRMergeMethod, error: String?, reason: String?) {
      self.anchor = anchor
      if !showing || !parent.valid() { remove(restore: true); return }
      schedulePresentation(anchor)
      if let surface { configure(surface, busy: busy, methods: methods, selected: selected, error: error, reason: reason) }
    }
    func anchorMoved(_ anchor: Anchor) {
      if anchor.window == nil { remove(restore: false) }
      else { schedulePresentation(anchor) }
    }
    func schedulePresentation(_ anchor: Anchor) {
      self.anchor = anchor
      let token = presentationToken
      DispatchQueue.main.async { [weak self, weak anchor] in
        guard let self, let anchor, self.active, self.presentationToken == token else { return }
        self.present(in: anchor)
      }
    }
    func present(in anchor: Anchor) {
      guard active, parent.state.showingMergeConfirmation, parent.valid(), let window = anchor.window,
        let content = window.contentView, window.attachedSheet == nil else { return }
      if let surface, surface.window === window { return }
      remove(restore: false)
      guard WindowModalInteraction.allows(anchor) else { return }
      self.window = window
      let responder = window.firstResponder
      returnView = (responder as? NSTextView)?.isFieldEditor == true
        ? (responder as? NSTextView)?.delegate as? NSView : responder as? NSView
      // Retained native menu overlays must not appear over the modal.
      content.subviews.compactMap { $0 as? SettingsPopupMenuButton.HostingView }.forEach { $0.dismissMenu?() }
      let surface = Surface(frame: content.bounds); surface.owner = self
      surface.autoresizingMask = [.width, .height]; self.surface = surface
      configure(surface, busy: parent.state.busy(for: parent.request), methods: parent.state.snapshot?.allowedMethods,
        selected: parent.state.selectedMethod, error: parent.state.error,
        reason: parent.state.mergeDisabledReason(for: parent.request, writable: parent.writable))
      content.addSubview(surface, positioned: .above, relativeTo: nil)
      WindowModalInteraction.install(surface, in: window)
      for button in [surface.squash, surface.merge, surface.cancel, surface.submit] {
        button.available = { [weak self] in self?.canAct() == true }
      }
      surface.squash.activate = { [weak self] in self?.select(.squash) }
      surface.merge.activate = { [weak self] in self?.select(.merge) }
      surface.cancel.available = { [weak self] in
        guard let self else { return false }
        return self.canAct() && !self.parent.state.busy(for: self.parent.request)
      }
      surface.submit.available = { [weak self] in self?.canSubmit() == true }
      surface.cancel.activate = { [weak self] in self?.dismiss() }
      surface.submit.activate = { [weak self] in self?.submit() }
      installMonitor(surface)
      surface.layoutSubtreeIfNeeded(); containFocus()
    }
    func configure(_ surface: Surface, busy: Bool, methods: [GitHubPRMergeMethod]?,
      selected: GitHubPRMergeMethod, error: String?, reason: String?) {
      surface.preferences = preferences
      surface.title.font = NSFont(descriptor: preferences.nativeFont(size: 20).fontDescriptor.addingAttributes(
        [.traits: [NSFontDescriptor.TraitKey.weight: NSFont.Weight.semibold.rawValue]]), size: 0)
      surface.subtitle.font = preferences.nativeFont(size: 13); surface.error.font = preferences.nativeFont(size: 13)
      surface.title.textColor = preferences.resolvedColors["textForeground"].nativeColor
      surface.subtitle.textColor = preferences.resolvedColors["textForegroundSecondary"].nativeColor
      surface.error.textColor = .systemRed; surface.error.stringValue = error ?? ""; surface.errorScroll.isHidden = error == nil
      let showMethods = methods == nil || (methods?.count ?? 0) > 1
      surface.squash.isHidden = !showMethods || methods?.contains(.squash) == false
      surface.merge.isHidden = !showMethods || methods?.contains(.merge) == false
      surface.squash.selected = selected == .squash; surface.merge.selected = selected == .merge
      surface.squash.setAccessibilityValue(selected == .squash ? 1 : 0)
      surface.merge.setAccessibilityValue(selected == .merge ? 1 : 0)
      surface.submit.title = selected.confirmationLabel; surface.submit.loading = busy
      surface.progress.appearance = NSAppearance(named: preferences.theme == "dark" ? .aqua : .darkAqua)
      surface.cancel.isEnabled = !busy; surface.submit.isEnabled = !busy && reason == nil; surface.submit.toolTip = reason
      for button in [surface.squash, surface.merge, surface.cancel, surface.submit] {
        button.font = preferences.nativeFont(size: 13); button.preferences = preferences; button.needsDisplay = true
      }
      surface.setAccessibilityHelp(showMethods ? "选择一种合并方式并确认。" : "确认所选的合并方式。")
      surface.setAccessibilityChildren([surface.subtitle, surface.squash, surface.merge, surface.errorScroll, surface.cancel, surface.submit].filter { !$0.isHidden })
      if busy { surface.progress.startAnimation(nil) } else { surface.progress.stopAnimation(nil) }
      surface.needsLayout = true; surface.needsDisplay = true
    }
    func select(_ method: GitHubPRMergeMethod) {
      guard canAct() else { return }; parent.state.selectMethod(method)
      if let surface { configure(surface, busy: parent.state.busy(for: parent.request), methods: parent.state.snapshot?.allowedMethods,
        selected: parent.state.selectedMethod, error: parent.state.error,
        reason: parent.state.mergeDisabledReason(for: parent.request, writable: parent.writable)) }
    }
    func dismiss() {
      guard canAct(), !parent.state.busy(for: parent.request) else { return }
      parent.state.showingMergeConfirmation = false; remove(restore: true)
    }
    private func canSubmit() -> Bool {
      canAct() && parent.state.mergeDisabledReason(for: parent.request, writable: parent.writable) == nil
    }
    func submit() {
      guard canSubmit() else { return }; parent.confirm()
    }
    func containFocus() {
      guard canAct(), let surface, let window else { return }
      if let editor = window.firstResponder as? NSTextView, editor.delegate as AnyObject? === surface.error { return }
      if let focused = window.firstResponder as? Button, surface.controls.contains(where: { $0 === focused }) { lastFocused = focused; return }
      let target = lastFocused.flatMap { surface.controls.contains($0) ? $0 : nil } ?? surface.controls.first
      if let target { window.makeFirstResponder(target); lastFocused = target }
      else { window.makeFirstResponder(nil) }
    }
    @discardableResult func handle(_ event: NSEvent) -> Bool {
      guard canAct(), event.window == nil || event.window === window else { return false }
      containFocus()
      let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
      if (event.keyCode == 53 && flags.isEmpty) || (flags == .command && event.charactersIgnoringModifiers == "w") {
        dismiss(); return true
      }
      if event.keyCode == 48, flags.isEmpty || flags == .shift, let surface {
        let controls = surface.controls; guard !controls.isEmpty else { return true }
        let current = controls.firstIndex { $0 === window?.firstResponder }
        let index = current.map { ($0 + (flags == .shift ? -1 : 1) + controls.count) % controls.count }
          ?? (flags == .shift ? controls.count - 1 : 0)
        window?.makeFirstResponder(controls[index]); lastFocused = controls[index]; return true
      }
      if flags.isEmpty, [36, 49, 76].contains(event.keyCode) {
        if !event.isARepeat, let button = window?.firstResponder as? Button { _ = button.accessibilityPerformPress() }
        return true
      }
      // These commands belong to the retained background workspace. Let normal
      // text selection/copy and application-level quit/minimize keep their route.
      if flags.contains(.command), let binding = ShortcutBinding(event: event),
        DesktopCommand.all.contains(where: { $0.defaultBindings.contains(binding) }) { return true }
      return false
    }
    private func installMonitor(_ surface: Surface) {
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
        let handled = MainActor.assumeIsolated {
          guard let self, self.window?.isKeyWindow == true, event.window === self.window, self.canAct() else { return false }
          if event.type == .keyDown { return self.handle(event) }
          self.containFocus(); return false
        }
        return handled ? nil : event
      }
      for name in [NSWindow.didUpdateNotification, NSWindow.didBecomeKeyNotification] {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { if self?.window?.isKeyWindow == true { self?.containFocus() } }
        })
      }
    }
    private func remove(restore: Bool) {
      guard let surface else { return }
      presentationToken = UUID()
      let oldWindow = window, previous = returnView
      surface.active = false; surface.owner = nil
      for button in [surface.squash, surface.merge, surface.cancel, surface.submit] { button.active = false; button.activate = nil }
      if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
      observers.forEach(NotificationCenter.default.removeObserver); observers = []
      if let oldWindow {
        WindowModalInteraction.remove(surface, from: oldWindow)
        if let focused = oldWindow.firstResponder as? NSView, focused === surface || focused.isDescendant(of: surface) {
          oldWindow.makeFirstResponder(nil)
        }
      }
      surface.removeFromSuperview(); self.surface = nil; window = nil; lastFocused = nil; returnView = nil
      let token = presentationToken
      if restore {
        DispatchQueue.main.async { [weak self, weak oldWindow, weak previous] in
          guard let self, self.active, self.presentationToken == token, !self.parent.state.showingMergeConfirmation,
            let oldWindow, let previous, oldWindow.isKeyWindow, oldWindow.attachedSheet == nil,
            previous.window === oldWindow, !previous.isHiddenOrHasHiddenAncestor, WindowModalInteraction.allows(previous) else { return }
          oldWindow.makeFirstResponder(previous)
        }
      }
    }
    func stop() { remove(restore: false); active = false }
    deinit {
      if let monitor { NSEvent.removeMonitor(monitor) }
      observers.forEach(NotificationCenter.default.removeObserver)
    }
  }
}
