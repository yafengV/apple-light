import AppKit
import SwiftUI

/// A same-window overlay: hovering must not transfer the composer's first responder.
struct WorkspaceLayoutMenuButton: NSViewRepresentable {
  let menu: WorkspaceLayoutMenu
  let shortcut: String
  let perform: (WorkspaceLayoutMenu.Action) -> Void
  @Environment(\.isEnabled) private var enabled
  @Environment(\.appAppearance) private var appearance
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> Trigger {
    let view = Trigger(); view.owner = context.coordinator
    view.target = context.coordinator; view.action = #selector(Coordinator.click(_:))
    view.isBordered = false
    return view
  }
  func updateNSView(_ view: Trigger, context: Context) {
    let coordinator = context.coordinator
    let previous = coordinator.parent.menu
    coordinator.parent = self; view.isEnabled = enabled
    view.preferences = appearance; view.needsDisplay = true
    view.setAccessibilityValue(menu.toolbarPressed.map { NSNumber(value: $0) })
    view.toolTip = "显示或隐藏标签页 " + shortcut
    view.setAccessibilityLabel("显示或隐藏标签页")
    view.setAccessibilityHelp(menu.entries.isEmpty ? view.toolTip : "\(menu.entries.count) 个打开的标签页")
    view.setAccessibilityRole(menu.kind == .toggle ? .button : .popUpButton)
    if previous.scope != menu.scope || previous.kind != menu.kind || !enabled { coordinator.dismiss(restore: false) }
    else if previous != menu { coordinator.refreshMenu() }
    coordinator.attach(view)
  }
  static func dismantleNSView(_ view: Trigger, coordinator: Coordinator) {
    coordinator.detach(); coordinator.active = false; view.owner = nil; view.target = nil
  }
  /// Toolbar anchors can sit above contentView; keep the popup inside its viewport.
  static func placement(anchor: NSRect, viewport: NSRect, height: CGFloat) -> NSRect? {
    let inset = viewport.insetBy(dx: 6, dy: 6)
    guard inset.width > 0, inset.height >= 48, anchor.maxX >= inset.minX, anchor.minX <= inset.maxX else { return nil }
    let width = min(288, inset.width), height = min(height, inset.height)
    return .init(x: max(inset.minX, min(anchor.maxX - width, inset.maxX - width)),
      y: max(inset.minY, min(anchor.minY - 8 - height, inset.maxY - height)), width: width, height: height)
  }
  static func inCorridor(_ point: NSPoint, from source: NSPoint, to rect: NSRect) -> Bool {
    let y = source.y >= rect.maxY ? rect.maxY : rect.minY
    let a = source, b = NSPoint(x: rect.minX - 4, y: y), c = NSPoint(x: rect.maxX + 4, y: y)
    func cross(_ p: NSPoint, _ q: NSPoint, _ r: NSPoint) -> CGFloat { (p.x-r.x)*(q.y-r.y) - (q.x-r.x)*(p.y-r.y) }
    guard abs(cross(a,b,c)) > 0.001 else { return false }
    let d = [cross(point,a,b), cross(point,b,c), cross(point,c,a)]
    return !(d.contains { $0 < 0 } && d.contains { $0 > 0 })
  }
  final class Trigger: NSButton {
    weak var owner: Coordinator?
    var preferences = AppearancePreferences()
    private var hovered = false
    private var tracking: NSTrackingArea?
    override func draw(_ dirtyRect: NSRect) {
      owner?.parent.menu.toolbarArtwork.draw(in: bounds, appearance: preferences, hovered: hovered, enabled: isEnabled, focused: window?.firstResponder === self)
    }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }
    override var intrinsicContentSize: NSSize { .init(width: 28, height: 26) }
    override var acceptsFirstResponder: Bool { isEnabled && owner?.active == true && WindowModalInteraction.allows(self) }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }
    override func updateTrackingAreas() {
      super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
      let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect,.mouseEnteredAndExited,.activeInKeyWindow], owner: self)
      addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true; owner?.hover(self) }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true; owner?.leave(from: event.locationInWindow, fromPopup: false) }
    override func keyDown(with event: NSEvent) {
      if owner?.triggerKey(event, button: self) == true { return }; super.keyDown(with: event)
    }
    override func accessibilityPerformPress() -> Bool {
      guard acceptsFirstResponder else { return false }
      if owner?.parent.menu.kind == .toggle { owner?.click(self) }
      else { owner?.open(self, keyboard: true) }
      return true
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); owner?.attach(self) }
  }
  final class Popup: NSView {
    weak var owner: Coordinator?
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
      super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
      let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect,.mouseEnteredAndExited,.activeInKeyWindow], owner: self)
      addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { owner?.cancelLeave() }
    override func mouseExited(with event: NSEvent) { owner?.leave(from: event.locationInWindow, fromPopup: true) }
  }
  final class Item: NSButton {
    weak var owner: Coordinator?
    var menuAction: WorkspaceLayoutMenu.Action?
    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled }
    override func becomeFirstResponder() -> Bool {
      let result = super.becomeFirstResponder()
      if result, let menuAction { owner?.focus(menuAction) }
      return result
    }
    override func resignFirstResponder() -> Bool { let result = super.resignFirstResponder(); owner?.refreshRows(); return result }
  }
  final class Row: NSView {
    let titleButton = Item(), fullButton = Item()
    private var tracking: NSTrackingArea?
    var hovered = false
    func refresh() {
      let focused = window?.firstResponder === titleButton || window?.firstResponder === fullButton
      fullButton.alphaValue = hovered || focused ? 1 : 0
      wantsLayer = true; layer?.cornerRadius = 8
      layer?.backgroundColor = hovered ? NSColor.quaternaryLabelColor.withAlphaComponent(0.12).cgColor : NSColor.clear.cgColor
    }
    override func updateTrackingAreas() {
      super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
      let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect,.mouseEnteredAndExited,.activeInKeyWindow], owner: self)
      addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; refresh() }
    override func mouseExited(with event: NSEvent) { hovered = false; refresh() }
  }
  @MainActor final class Coordinator: NSObject {
    var parent: WorkspaceLayoutMenuButton
    var active = true
    var interaction = WorkspaceLayoutMenuInteraction()
    private weak var trigger: Trigger?
    private weak var window: NSWindow?
    private(set) var popup: Popup?
    private var buttons: [Item] = []
    private var rows: [Row] = []
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private weak var pointerSurface: NSView?
    private var pointerTracking: NSTrackingArea?
    private var timer: Timer?
    private var sourcePoint: NSPoint?
    private var travelToTrigger = false
    private weak var nextAfterTrigger: NSView?
    init(_ parent: WorkspaceLayoutMenuButton) { self.parent = parent }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) }; observers.forEach(NotificationCenter.default.removeObserver); timer?.invalidate() }
    var available: Bool { active && parent.enabled && trigger?.acceptsFirstResponder == true && window?.attachedSheet == nil }
    @objc func click(_ button: Trigger) {
      guard available, button === trigger else { return }
      let action: WorkspaceLayoutMenu.Action = parent.menu.kind == .newTab ? .create(.split) : .toggle
      dismiss(restore: false); parent.perform(action)
    }
    func hover(_ button: Trigger) {
      guard available, parent.menu.kind != .toggle else { return }
      cancelLeave(); if popup == nil { open(button, keyboard: false) }
    }
    func open(_ button: Trigger, keyboard: Bool, last: Bool = false) {
      guard available, parent.menu.kind != .toggle, let window = button.window, let content = window.contentView else { return }
      if popup == nil {
        // Close another workspace chooser in this window without changing first responder.
        content.subviews.compactMap { $0 as? Popup }.forEach { $0.owner?.dismiss(restore: false) }
        let height: CGFloat = parent.menu.kind == .retained ? CGFloat(parent.menu.entries.count * 32 + 40) : 80
        guard let frame = WorkspaceLayoutMenuButton.placement(anchor: button.convert(button.bounds,to:nil),
          viewport: content.convert(content.bounds,to:nil),height: min(height,360)) else { return }
        let view = Popup(frame: content.convert(frame,from:nil)); view.owner = self
        view.wantsLayer = true; view.layer?.cornerRadius = 12
        view.layer?.backgroundColor = NSColor(parent.appearance.backgroundColor).cgColor
        view.layer?.borderWidth = 1; view.layer?.borderColor = parent.appearance.resolvedColors["border"].nativeColor.cgColor
        view.setAccessibilityElement(true); view.setAccessibilityRole(.group); view.setAccessibilityLabel("显示或隐藏标签页")
        nextAfterTrigger = button.nextValidKeyView
        popup = view; buildRows(view); content.addSubview(view,positioned:.above,relativeTo:nil)
        interaction.open(keyboard ? .keyboard : .hover)
        button.setAccessibilityExpanded(true)
      }
      if keyboard {
        cancelLeave(); interaction.keyboard(parent.menu,last:last)
        if let item = last ? buttons.last(where: \.isEnabled) : buttons.first(where: \.isEnabled) {
          window.makeFirstResponder(item); item.scrollToVisible(item.bounds)
        }
      }
    }
    private func buildRows(_ popup: Popup) {
      let headerHeight: CGFloat = parent.menu.kind == .retained ? 28 : 0
      if headerHeight > 0 {
        let header = NSTextField(labelWithString:"已打开的标签页")
        header.font = parent.appearance.nativeFont(size:12); header.textColor = .tertiaryLabelColor
        header.frame = .init(x:16,y:popup.bounds.height-28,width:popup.bounds.width-32,height:18); popup.addSubview(header)
      }
      let scroll = NSScrollView(frame:.init(x:8,y:8,width:popup.bounds.width-16,height:popup.bounds.height-16-headerHeight))
      scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
      let items = parent.menu.kind == .retained ? parent.menu.entries : [
        .init(id:"split",title:"新建标签页",icon:"plus"), .init(id:"full",title:"在完整视图中打开新标签页",icon:"arrow.up.left.and.arrow.down.right")]
      let document = NSView(frame:.init(x:0,y:0,width:scroll.bounds.width,height:CGFloat(items.count)*32))
      for (index,entry) in items.enumerated() {
        let row = Row(frame:.init(x:0,y:CGFloat(items.count-index-1)*32,width:document.bounds.width,height:32))
        let title = row.titleButton
        title.title = entry.title; title.image = NSImage(systemSymbolName:entry.icon,accessibilityDescription:nil)
        title.imagePosition = .imageLeading; title.alignment = .left; title.lineBreakMode = .byTruncatingTail
        title.frame = .init(x:8,y:0,width:row.bounds.width-(parent.menu.kind == .retained ? 48 : 16),height:32)
        configure(title,action:parent.menu.kind == .retained ? .select(entry.id,.split) : .create(index == 0 ? .split : .full), enabled:entry.enabled)
        title.setAccessibilityLabel(entry.title); row.addSubview(title)
        if parent.menu.kind == .retained {
          let full = row.fullButton
          full.image = NSImage(systemSymbolName:"arrow.up.left.and.arrow.down.right",accessibilityDescription:nil)
          full.frame = .init(x:row.bounds.width-32,y:4,width:28,height:24)
          configure(full,action:.select(entry.id,.full),enabled:entry.enabled)
          full.setAccessibilityLabel("在完整视图中打开 " + entry.title); full.toolTip = "在完整视图中打开 " + entry.title
          row.addSubview(full); row.refresh()
        }
        rows.append(row); document.addSubview(row)
      }
      scroll.documentView = document; popup.addSubview(scroll)
      document.scroll(.init(x:0,y:max(0,document.bounds.height-scroll.bounds.height)))
    }
    private func configure(_ item: Item, action: WorkspaceLayoutMenu.Action, enabled: Bool) {
      item.owner = self; item.menuAction = action; item.isBordered = false; item.isEnabled = enabled
      item.font = parent.appearance.nativeFont(size:12); item.contentTintColor = NSColor(parent.appearance.foregroundColor)
      item.target = self; item.action = #selector(select(_:)); buttons.append(item)
    }
    @objc func select(_ item: Item) {
      guard available, popup != nil, item.window === window, buttons.contains(where: { $0 === item }),
        item.isEnabled, let action = item.menuAction, parent.menu.accepts(action) else { return }
      dismiss(restore:false); parent.perform(action)
    }
    func refreshRows() { rows.forEach { $0.refresh() } }
    func refreshMenu() {
      guard available, let popup, let trigger, let content = window?.contentView else { return }
      let focused = window?.firstResponder as? Item
      let action = focused?.menuAction
      let height: CGFloat = parent.menu.kind == .retained ? CGFloat(parent.menu.entries.count*32+40) : 80
      guard let frame = WorkspaceLayoutMenuButton.placement(anchor:trigger.convert(trigger.bounds,to:nil),
        viewport:content.convert(content.bounds,to:nil),height:min(height,360)) else { dismiss(restore:false); return }
      if focused != nil { window?.makeFirstResponder(trigger) }
      popup.subviews.forEach { $0.removeFromSuperview() }; buttons = []; rows = []
      popup.frame = content.convert(frame,from:nil); buildRows(popup)
      if let action, let item = buttons.first(where: { $0.menuAction == action && $0.isEnabled }) {
        window?.makeFirstResponder(item); item.scrollToVisible(item.bounds)
      } else if focused != nil { interaction.keyboard(parent.menu); if let item = buttons.first(where: \.isEnabled) { window?.makeFirstResponder(item) } }
    }
    func focus(_ action: WorkspaceLayoutMenu.Action) { cancelLeave(); interaction.focus(action); refreshRows() }
    func triggerKey(_ event: NSEvent, button: Trigger) -> Bool {
      guard available, event.modifierFlags.intersection([.command,.option,.control,.shift]).isEmpty else { return false }
      guard [36,49,76,125,126].contains(event.keyCode), parent.menu.kind != .toggle else { return false }
      if popup != nil || event.keyCode == 125 || event.keyCode == 126 || parent.menu.kind == .newTab {
        open(button,keyboard:true,last:event.keyCode == 126)
      } else { click(button) }
      return true
    }
    func cancelLeave() { timer?.invalidate(); timer = nil; sourcePoint = nil; interaction.enter() }
    func leave(from point: NSPoint, fromPopup: Bool) {
      guard interaction.origin == .hover, popup != nil else { return }
      sourcePoint = point; travelToTrigger = fromPopup
      interaction.leave(now:ProcessInfo.processInfo.systemUptime); armTimer()
    }
    private func armTimer() {
      timer?.invalidate()
      timer = Timer.scheduledTimer(withTimeInterval:0.1,repeats:false) { [weak self] _ in
        MainActor.assumeIsolated { self?.dismiss(restore:false) }
      }
    }
    func dismiss(restore: Bool) {
      let keyboard = interaction.origin == .keyboard
      timer?.invalidate(); timer = nil; sourcePoint = nil
      interaction.dismiss(); popup?.removeFromSuperview(); popup = nil; buttons = []; rows = []
      trigger?.setAccessibilityExpanded(false)
      if restore, keyboard, available, let trigger { window?.makeFirstResponder(trigger) }
    }
    func detach() {
      dismiss(restore:false); if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
      if let pointerTracking { pointerSurface?.removeTrackingArea(pointerTracking) }
      pointerTracking = nil; pointerSurface = nil
      observers.forEach(NotificationCenter.default.removeObserver); observers = []; window = nil; trigger = nil
    }
    func attach(_ button: Trigger) {
      guard button.window !== window else { trigger = button; return }; detach(); trigger = button
      guard active, let nativeWindow = button.window else { return }; window = nativeWindow
      // Receive travel through the toolbar-to-menu gap even when the separate
      // pointer-cursor preference does not enable window mouse-moved events.
      if let content = nativeWindow.contentView {
        let surface = content.superview ?? content
        let area = NSTrackingArea(rect:.zero,options:[.inVisibleRect,.mouseMoved,.activeInKeyWindow],owner:self)
        surface.addTrackingArea(area); pointerSurface = surface; pointerTracking = area
      }
      for name in [NSWindow.didResignKeyNotification,NSWindow.willCloseNotification,NSWindow.didResizeNotification] {
        observers.append(NotificationCenter.default.addObserver(forName:name,object:nativeWindow,queue:.main) { [weak self] _ in
          MainActor.assumeIsolated { self?.dismiss(restore:false) }
        })
      }
      monitor = NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.leftMouseDown,.rightMouseDown,.mouseMoved]) { [weak self] event in
        let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }; return handled ? nil : event
      }
    }
    @objc func mouseMoved(with event: NSEvent) { _ = handle(event) }
    func handle(_ event: NSEvent) -> Bool {
      guard let window, event.window === window, popup != nil, let trigger else { return false }
      guard available else { dismiss(restore:false); return false }
      if event.type == .mouseMoved {
        guard interaction.origin == .hover, let sourcePoint, let popup else { return false }
        let point = event.locationInWindow, destination = travelToTrigger
          ? trigger.convert(trigger.bounds,to:nil) : popup.convert(popup.bounds,to:nil)
        if destination.contains(point) { cancelLeave() }
        else if WorkspaceLayoutMenuButton.inCorridor(point,from:sourcePoint,to:destination) {
          interaction.leave(now:event.timestamp); armTimer()
        } else { dismiss(restore:false) }
        return false
      }
      if event.type != .keyDown {
        if popup?.convert(popup!.bounds,to:nil).contains(event.locationInWindow) != true,
          !trigger.convert(trigger.bounds,to:nil).contains(event.locationInWindow) { dismiss(restore:false) }
        return false
      }
      if event.keyCode == 53 { dismiss(restore:true); return true }
      let focused = window.firstResponder as? NSView
      guard focused === trigger || (popup.map { focused?.isDescendant(of:$0) == true } ?? false) else { return false }
      let flags = event.modifierFlags.intersection([.command,.option,.control,.shift])
      guard flags.isEmpty || flags == .shift else { return false }
      if focused === trigger { return triggerKey(event,button:trigger) }
      let candidates = buttons.filter(\.isEnabled)
      let navigationKeys: [UInt16] = parent.menu.kind == .newTab ? [125,126] : [48]
      if navigationKeys.contains(event.keyCode), !candidates.isEmpty {
        let delta = event.keyCode == 126 || flags == .shift ? -1 : 1
        let index = candidates.firstIndex { $0 === focused } ?? (delta > 0 ? -1 : 0)
        if parent.menu.kind == .retained, !(0..<candidates.count).contains(index+delta) {
          let target = delta < 0 ? trigger : nextAfterTrigger
          dismiss(restore:false)
          if let target { window.makeFirstResponder(target) } else { window.selectNextKeyView(trigger) }
          return true
        }
        let next = candidates[(index+delta+candidates.count)%candidates.count]
        window.makeFirstResponder(next); next.scrollToVisible(next.bounds); return true
      }
      if parent.menu.kind == .newTab, event.keyCode == 48 { return true }
      if [36,49,76].contains(event.keyCode), let item = focused as? Item { select(item); return true }
      return false
    }
  }
}
