import AppKit
import SwiftUI

/// Keep the menu in the invoking window, above the settings scroll container.
@MainActor protocol SettingsPopupMenuState: AnyObject {
  var presented: Bool { get }
  var highlightedID: String? { get set }
  func dismiss()
  func move(_ delta: Int)
  func edge(last: Bool)
  func type(_ character: String, now: TimeInterval)
  func space(now: TimeInterval) -> Bool
}

struct SettingsPopupMenuButton: NSViewRepresentable {
  let title: String
  let label: String
  let menu: any SettingsPopupMenuState
  var buttonWidth: CGFloat = 176
  var fitsTitle = false
  var fontSize: CGFloat = 14
  var menuWidth: CGFloat = 240
  var icon: ((NSRect, NSColor, Bool) -> Void)? = nil
  var formStyle: SettingsMenuTriggerStyle? = nil
  var swatch: SettingsMenuSwatch? = nil
  var accent: AppearanceRGBA? = nil
  var dismissOnWindowBlur = true
  var focusTriggerBeforeSelection = false
  var restoreFocusAfterSelection = true
  var commentMenuShadow = false
  let menuHeight: () -> CGFloat
  let available: Bool
  let open: (Bool) -> Void
  let choose: (String) -> Bool
  let content: (@escaping (String) -> Void) -> AnyView
  @Environment(\.isEnabled) private var enabled
  @Environment(\.appAppearance) private var appearance
  @Environment(\.layoutDirection) private var direction
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> Control {
    let button = Control(); button.owner = context.coordinator
    button.target = context.coordinator; button.action = #selector(Coordinator.clicked(_:))
    button.isBordered = false; button.setAccessibilityElement(true); button.setAccessibilityRole(.popUpButton)
    return button
  }
  func updateNSView(_ button: Control, context: Context) {
    let owner = context.coordinator; owner.parent = self
    owner.needsRootUpdate = true
    button.isEnabled = enabled && available
    button.title = title
    button.font = appearance.nativeFont(size: formStyle?.fontSize ?? fontSize)
    button.foreground = NSColor(appearance.foregroundColor)
    button.surface = formStyle.map { appearance.resolvedColors[$0.backgroundRole].nativeColor }
      ?? appearance.resolvedColors["textForeground"].opacity(0.025).nativeColor
    button.hoverSurface = appearance.resolvedColors["buttonSecondaryBackgroundHover"].nativeColor
    button.chevronColor = appearance.resolvedColors["textForegroundTertiary"].nativeColor
    button.expanded = menu.presented
    button.border = appearance.resolvedColors["border"].nativeColor
    button.focusBorder = appearance.resolvedColors["borderFocus"].nativeColor
    button.buttonWidth = buttonWidth
    button.fitsTitle = fitsTitle
    button.icon = icon
    button.formTrigger = formStyle.map { .init(appearance: appearance, swatch: swatch, direction: direction, style: $0, accent: accent) }
    button.invalidateIntrinsicContentSize()
    button.setAccessibilityLabel(label)
    button.setAccessibilityValue(button.title); button.setAccessibilityExpanded(menu.presented)
    button.needsDisplay = true; owner.schedule(button)
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: Control, context: Context) -> CGSize? {
    guard fitsTitle else { return nil }
    let ideal = nsView.intrinsicContentSize
    return .init(width: min(ideal.width, proposal.width ?? ideal.width), height: ideal.height)
  }
  static func dismantleNSView(_ button: Control, coordinator: Coordinator) {
    coordinator.active = false; coordinator.detach(); button.formTrigger = nil; button.active = false; button.owner = nil; button.target = nil
  }
  static func placement(anchor: NSRect, viewport: NSRect, height: CGFloat, width: CGFloat = 240) -> NSRect? {
    let available = viewport.insetBy(dx: 6, dy: 6)
    guard anchor.intersects(available), available.width > 0 else { return nil }
    let below = max(0, anchor.minY - available.minY - 2), above = max(0, available.maxY - anchor.maxY - 2)
    let useBelow = below >= height || below >= above
    let fitted = min(height, useBelow ? below : above)
    guard fitted > 0, fitted >= min(38, height) else { return nil }
    let width = min(width, available.width)
    return .init(x: max(available.minX, min(anchor.maxX - width, available.maxX - width)),
      y: useBelow ? anchor.minY - 2 - fitted : anchor.maxY + 2, width: width, height: fitted)
  }
  static func hasOpenMenu(in window: NSWindow) -> Bool {
    window.contentView?.subviews.contains { $0 is HostingView } == true
  }
  final class HostingView: NSHostingView<AnyView> {
    var dismissMenu: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
  }
  final class Control: NSButton {
    weak var owner: Coordinator?
    var active = true
    var foreground = NSColor.labelColor
    var surface = NSColor.controlBackgroundColor
    var hoverSurface = NSColor.controlBackgroundColor
    var chevronColor = NSColor.secondaryLabelColor
    var expanded = false { didSet { if oldValue != expanded { refreshSurface() } } }
    var hovered = false { didSet { if oldValue != hovered { refreshSurface() } } }
    private var hoverArea: NSTrackingArea?
    var border = NSColor.separatorColor
    var focusBorder = NSColor.keyboardFocusIndicatorColor
    var buttonWidth: CGFloat = 176
    var fitsTitle = false
    var icon: ((NSRect, NSColor, Bool) -> Void)?
    var formTrigger: SettingsMenuTriggerConfiguration? { didSet { refreshSurface() } }
    private var formHost: SettingsMenuTriggerHostingView?
    var keyboardFocus = true
    private var formFocused = false
    private func refreshSurface() {
      needsDisplay = true
      guard let formTrigger else { formHost?.removeFromSuperview(); formHost = nil; return }
      focusRingType = .none
      let view = AnyView(SettingsMenuTriggerSurface(title: title, swatch: formTrigger.swatch,
        style: formTrigger.style, accent: formTrigger.accent, hovered: hovered, open: expanded,
        focused: formFocused)
        .disabled(!isEnabled).padding(SettingsMenuTriggerMetrics.focusRing)
        .environment(\.appAppearance, formTrigger.appearance).environment(\.layoutDirection, formTrigger.direction))
      if let formHost { formHost.rootView = view }
      else { let host = SettingsMenuTriggerHostingView(rootView: view); host.setAccessibilityElement(false); addSubview(host); formHost = host }
      needsLayout = true
    }
    override func becomeFirstResponder() -> Bool {
      let result = super.becomeFirstResponder()
      if result { formFocused = keyboardFocus; keyboardFocus = true; refreshSurface() }
      return result
    }
    override func resignFirstResponder() -> Bool {
      let result = super.resignFirstResponder()
      if result { formFocused = false; DispatchQueue.main.async { [weak self] in self?.refreshSurface() } }
      return result
    }
    private var requestedEnabled = true
    private var generation = UUID()
    override var isEnabled: Bool {
      get { requestedEnabled }
      set {
        guard requestedEnabled != newValue else { return }; requestedEnabled = newValue; refreshSurface()
        generation = UUID(); let token = generation
        DispatchQueue.main.async { [weak self] in
          guard let self, self.generation == token else { return }
          self.applyEnabled(newValue)
        }
      }
    }
    private func applyEnabled(_ value: Bool) {
      if !value, window?.firstResponder === self { window?.makeFirstResponder(nil) }
      super.isEnabled = value; refreshSurface()
    }
    override var acceptsFirstResponder: Bool { active && isEnabled && !isHiddenOrHasHiddenAncestor && WindowModalInteraction.allows(self) }
    override var canBecomeKeyView: Bool { acceptsFirstResponder && window != nil }
    override var intrinsicContentSize: NSSize {
      guard fitsTitle, let configuration = formTrigger else { return .init(width: buttonWidth, height: icon == nil ? 28 : 24) }
      // SwiftUI rounds its text layout outward. NSString can report a half
      // point less for fallback CJK glyphs, which would truncate a natural title.
      let titleWidth = ceil((title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: configuration.style.fontSize)]).width)
      let style = configuration.style
      let visual: CGFloat = configuration.swatch != nil ? SettingsMenuTriggerMetrics.swatchSize
        : configuration.accent != nil ? 12 : 0
      let leading = configuration.swatch != nil ? style.swatchPadding : style.padding
      return .init(width: titleWidth + leading + style.padding + 2 * SettingsMenuTriggerMetrics.border
        + SettingsMenuTriggerMetrics.chevronSize + SettingsMenuTriggerMetrics.gap
        + (visual > 0 ? visual + SettingsMenuTriggerMetrics.swatchGap : 0), height: SettingsMenuTriggerMetrics.height)
    }
    override func draw(_ dirtyRect: NSRect) {
      if formTrigger != nil { return }
      if let icon {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5), path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        if expanded || hovered { hoverSurface.setFill(); path.fill() }
        icon(.init(x: bounds.midX - 8, y: bounds.midY - 8, width: 16, height: 16),
          foreground.withAlphaComponent(isEnabled ? 1 : 0.5), isFlipped)
        if window?.firstResponder === self { focusBorder.setStroke(); path.lineWidth = 2; path.stroke() }
        return
      }
      let rect = bounds.insetBy(dx: 0.5, dy: 0.5), path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
      let fill = expanded || hovered ? hoverSurface : surface
      fill.withAlphaComponent(fill.alphaComponent * (isEnabled ? 1 : 0.5)).setFill(); path.fill()
      border.setStroke(); path.lineWidth = 1; path.stroke()
      let font = font ?? .systemFont(ofSize: 14)
      let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
      let label = NSAttributedString(string: title, attributes: [.font: font,
        .foregroundColor: foreground.withAlphaComponent(isEnabled ? 1 : 0.5), .paragraphStyle: paragraph])
      label.draw(in: .init(x: 10, y: (bounds.height - label.size().height) / 2, width: bounds.width - 36, height: label.size().height))
      let chevron = NSBezierPath()
      chevron.move(to: .init(x: bounds.maxX - 19, y: bounds.midY + 2))
      chevron.line(to: .init(x: bounds.maxX - 15, y: bounds.midY - 2))
      chevron.line(to: .init(x: bounds.maxX - 11, y: bounds.midY + 2))
      chevronColor.withAlphaComponent(chevronColor.alphaComponent * (isEnabled ? 1 : 0.5)).setStroke(); chevron.lineWidth = 1.4; chevron.stroke()
      if window?.firstResponder === self {
        focusBorder.setStroke(); path.lineWidth = 2; path.stroke()
      }
    }
    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      if let hoverArea { removeTrackingArea(hoverArea) }
      let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
      addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {
      guard acceptsFirstResponder else { return }
      keyboardFocus = false; formFocused = false; refreshSurface()
      window?.makeFirstResponder(self); super.mouseDown(with: event)
    }
    override func keyDown(with event: NSEvent) {
      let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
      if acceptsFirstResponder, flags.isEmpty, [36, 49, 76, 125].contains(event.keyCode) {
        keyboardFocus = true; formFocused = true; refreshSurface()
        if !event.isARepeat { owner?.toggle(self, keyboard: true) }; return
      }
      super.keyDown(with: event)
    }
    override func accessibilityPerformPress() -> Bool {
      guard acceptsFirstResponder else { return false }; owner?.toggle(self, keyboard: true); return true
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); owner?.attach(self) }
    override func layout() {
      super.layout()
      formHost?.frame = bounds.insetBy(dx: -SettingsMenuTriggerMetrics.focusRing, dy: -SettingsMenuTriggerMetrics.focusRing)
      owner?.schedule(self)
    }
  }
  @MainActor final class Coordinator: NSObject {
    var parent: SettingsPopupMenuButton
    var active = true
    var needsRootUpdate = true
    private var scheduled = false
    private var openingKeyboardFocus = true
    private var observers: [NSObjectProtocol] = []
    private var monitor: Any?
    private(set) var popup: HostingView?
    private weak var observedWindow: NSWindow?
    init(_ parent: SettingsPopupMenuButton) { self.parent = parent }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) }; if let monitor { NSEvent.removeMonitor(monitor) } }
    @objc func clicked(_ button: Control) { toggle(button, keyboard: false) }
    func toggle(_ button: Control, keyboard: Bool) {
      guard active, button.acceptsFirstResponder, parent.enabled, parent.available else { return }
      openingKeyboardFocus = keyboard
      if parent.menu.presented { dismiss(button, restore: true) }
      else {
        button.window?.contentView?.subviews.compactMap { $0 as? HostingView }.forEach { $0.dismissMenu?() }
        parent.open(keyboard); update(button)
      }
    }
    func choose(_ id: String, button: Control) {
      guard active, button.window != nil, button.acceptsFirstResponder, parent.enabled, parent.available, parent.menu.presented else { return }
      if parent.focusTriggerBeforeSelection { button.window?.makeFirstResponder(button) }
      if parent.choose(id) { dismiss(button, restore: parent.restoreFocusAfterSelection) }
    }
    func dismiss(_ button: Control, restore: Bool) {
      parent.menu.dismiss(); popup?.removeFromSuperview(); popup = nil; button.expanded = false; button.setAccessibilityExpanded(false)
      // Complete the native close before returning to AppKit's event loop.
      // A queued restoration can otherwise consume the next Tab or override
      // a later field editor (including its selection).
      guard restore, active, !parent.menu.presented, button.acceptsFirstResponder,
        let window = button.window, window.attachedSheet == nil else { return }
      button.keyboardFocus = openingKeyboardFocus
      window.makeFirstResponder(button); button.keyboardFocus = true; button.needsDisplay = true
    }
    func detach() {
      parent.menu.dismiss(); popup?.removeFromSuperview(); popup = nil
      observers.forEach { NotificationCenter.default.removeObserver($0) }; observers = []
      if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil; observedWindow = nil
    }
    func attach(_ button: Control) {
      guard button.window !== observedWindow else { return }; detach()
      guard active, let window = button.window else { return }; observedWindow = window
      var ancestor: NSView? = button
      while let view = ancestor {
        view.postsBoundsChangedNotifications = true; view.postsFrameChangedNotifications = true
        for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
          observers.append(NotificationCenter.default.addObserver(forName: name, object: view, queue: .main) { [weak self, weak button] _ in
            MainActor.assumeIsolated { if let button { self?.schedule(button) } }
          })
        }
        ancestor = view.superview
      }
      for name in [NSWindow.didResizeNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification, NSWindow.didUpdateNotification] {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self, weak button] note in
          MainActor.assumeIsolated { guard let self, let button else { return }
            if note.name == NSWindow.didResizeNotification { self.schedule(button) }
            else if note.name == NSWindow.didUpdateNotification {
              if let popup = self.popup, let first = button.window?.firstResponder as? NSView,
                first !== button, !first.isDescendant(of: popup),
                ((first as? NSTextView)?.delegate as? NSView)?.isDescendant(of: popup) != true { self.dismiss(button, restore: false) }
            } else if note.name != NSWindow.didResignKeyNotification || self.parent.dismissOnWindowBlur {
              self.dismiss(button, restore: false)
            }
          }
        })
      }
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self, weak button] event in
        let handled = MainActor.assumeIsolated {
          guard let self, let button, let window = button.window, window.isKeyWindow, event.window === window else { return false }
          return self.handle(event, button: button)
        }
        return handled ? nil : event
      }
    }
    func handle(_ event: NSEvent, button: Control) -> Bool {
      guard active, parent.menu.presented, let window = button.window, event.window === window else { return false }
      guard button.acceptsFirstResponder, parent.enabled, parent.available else { dismiss(button, restore: false); return false }
      if event.type != .keyDown {
        let point = event.locationInWindow
        let containsPopup = popup.map { $0.convert($0.bounds, to: nil).contains(point) } ?? false
        if !containsPopup,
          !button.convert(button.bounds, to: nil).contains(point) { dismiss(button, restore: false) }
        return false
      }
      guard button.window?.attachedSheet == nil, (button.window?.firstResponder as? NSTextView)?.hasMarkedText() != true else { return false }
      if let editor = button.window?.firstResponder as? NSTextView, editor.isEditable,
        let popup, editor.isDescendant(of: popup) || (editor.delegate as? NSView)?.isDescendant(of: popup) == true { return false }
      let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
      guard flags.isEmpty || flags == .shift else { return false }
      switch event.keyCode {
      case 53: dismiss(button, restore: true)
      case 48: break // The reference menu prevents Tab from leaving the menu.
      case 125: parent.menu.move(1)
      case 126: parent.menu.move(-1)
      case 115, 116: parent.menu.edge(last: false)
      case 119, 121: parent.menu.edge(last: true)
      case 36, 76:
        if let id = parent.menu.highlightedID { choose(id, button: button) }
      case 49:
        if parent.menu.space(now: event.timestamp), let id = parent.menu.highlightedID { choose(id, button: button) }
      default:
        guard let text = event.characters, text.utf16.count == 1 else { return false }
        parent.menu.type(text, now: event.timestamp)
      }
      return true
    }
    func schedule(_ button: Control) {
      guard active, !scheduled else { return }; scheduled = true
      DispatchQueue.main.async { [weak self, weak button] in
        guard let self else { return }; self.scheduled = false; if let button { self.update(button) }
      }
    }
    private func update(_ button: Control) {
      guard active else { return }
      if button.window !== observedWindow { attach(button); return }
      guard parent.menu.presented else { popup?.removeFromSuperview(); popup = nil; return }
      guard parent.enabled, parent.available, button.acceptsFirstResponder, !button.visibleRect.isEmpty,
        let window = button.window, window.attachedSheet == nil, let content = window.contentView else { dismiss(button, restore: false); return }
      let anchor = button.convert(button.bounds, to: nil), viewport = content.convert(content.bounds, to: nil)
      let height = parent.menuHeight()
      guard let frame = SettingsPopupMenuButton.placement(anchor: anchor, viewport: viewport, height: height, width: parent.menuWidth) else { dismiss(button, restore: false); return }
      let root = AnyView(parent.content({ [weak self, weak button] id in
        if let button { self?.choose(id, button: button) }
      }).environment(\.appAppearance, parent.appearance))
      let host = popup ?? HostingView(rootView: root); host.sizingOptions = []
      host.dismissMenu = { [weak self, weak button] in if let button { self?.dismiss(button, restore: false) } }
      if popup == nil || needsRootUpdate { host.rootView = root; needsRootUpdate = false }
      let converted = content.convert(frame, from: nil)
      if host.frame != converted { host.frame = converted }; host.focusRingType = .none
      if parent.commentMenuShadow {
        host.wantsLayer = true
        host.layer?.masksToBounds = false
        host.layer?.shadowColor = NSColor.black.cgColor
        host.layer?.shadowOpacity = 0.12; host.layer?.shadowRadius = 8
        host.layer?.shadowOffset = .init(width: 0, height: -8)
        host.layer?.shadowPath = CGPath(roundedRect: host.bounds.insetBy(dx: 4, dy: 4), cornerWidth: 12, cornerHeight: 12, transform: nil)
      }
      if host.superview !== content { content.addSubview(host, positioned: .above, relativeTo: nil); window.makeFirstResponder(host) }
      popup = host; button.expanded = true; button.setAccessibilityExpanded(true)
    }
  }
}
