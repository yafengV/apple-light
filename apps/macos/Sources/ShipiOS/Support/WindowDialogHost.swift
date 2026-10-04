import AppKit

/// Native dialogs use the owning window's content surface. Their form owns
/// validation and data; this host owns presentation, focus and event scope.
@MainActor class WindowDialogSurface: NSView, WindowModalScope {
  weak var host: WindowDialogHost?
  var active = true
  var dialogFrame: NSRect { .zero }
  var focusTargets: [NSView] { [] }
  var initialFocus: NSView? { focusTargets.first }
  func retainsContentFocus(_ view: NSView) -> Bool { false }
  var modalRoot: NSView { self }
  var modalScopeActive: Bool { active && host?.isCurrent(self) == true }
  var blocksWorkspaceCommands: Bool { true }
  override var isFlipped: Bool { true }
  override func accessibilityFrame() -> NSRect {
    guard let window else { return .zero }; return window.convertToScreen(convert(dialogFrame, to: nil))
  }
  override func mouseDown(with event: NSEvent) {
    if !event.modifierFlags.contains(.control), !dialogFrame.contains(convert(event.locationInWindow, from: nil)) { host?.dismiss() }
  }
  override func rightMouseDown(with event: NSEvent) {}
  override func otherMouseDown(with event: NSEvent) {
    if !dialogFrame.contains(convert(event.locationInWindow, from: nil)) { host?.dismiss() }
  }
}

@MainActor final class WindowDialogHost {
  final class Anchor: NSView {
    weak var host: WindowDialogHost?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if window == nil { host?.remove(restore: false) } else { host?.schedule(self) }
    }
  }
  var identity: (() -> String?) = { nil }
  var valid: (() -> Bool) = { false }
  var canDismiss: (() -> Bool) = { false }
  var onDismiss: (() -> Void) = {}
  var key: ((NSEvent) -> Bool) = { _ in false }
  var make: ((NSRect) -> WindowDialogSurface)?
  private(set) var surface: WindowDialogSurface?
  private(set) weak var window: NSWindow?
  private var shownIdentity: String?
  private var active = true
  private var token = UUID()
  private var monitor: Any?
  private var observers: [NSObjectProtocol] = []
  private weak var returnView: NSView?
  private weak var lastFocus: NSView?

  func isCurrent(_ surface: WindowDialogSurface) -> Bool {
    active && self.surface === surface && surface.active && window != nil && surface.window === window
      && window?.attachedSheet == nil && valid() && shownIdentity != nil && identity() == shownIdentity
  }
  func canAct() -> Bool { surface.map { isCurrent($0) && WindowModalInteraction.allows($0) } == true }
  func update(_ anchor: Anchor) {
    guard active else { return }
    if !valid() || identity() == nil { remove(restore: true); return }
    if surface != nil, shownIdentity != identity() || window !== anchor.window { present(anchor); return }
    schedule(anchor)
  }
  func schedule(_ anchor: Anchor) {
    let scheduled = token
    DispatchQueue.main.async { [weak self, weak anchor] in
      guard let self, let anchor, self.active, self.token == scheduled else { return }; self.present(anchor)
    }
  }
  func present(_ anchor: Anchor) {
    guard active, valid(), let identity = identity(), let window = anchor.window,
      window.attachedSheet == nil, let content = window.contentView else { return }
    if shownIdentity == identity, surface?.window === window { return }
    let previousSource = self.window === window ? returnView : nil
    remove(restore: false)
    guard WindowModalInteraction.allows(anchor), let make else { return }
    self.window = window; shownIdentity = identity
    let responder = window.firstResponder
    returnView = previousSource ?? ((responder as? NSTextView)?.isFieldEditor == true
      ? (responder as? NSTextView)?.delegate as? NSView : responder as? NSView)
    content.subviews.compactMap { $0 as? SettingsPopupMenuButton.HostingView }.forEach { $0.dismissMenu?() }
    let surface = make(content.bounds); surface.host = self; surface.autoresizingMask = [.width, .height]
    self.surface = surface; content.addSubview(surface, positioned: .above, relativeTo: nil)
    WindowModalInteraction.install(surface, in: window)
    installMonitor(); surface.layoutSubtreeIfNeeded(); containFocus()
  }
  func containFocus() {
    guard canAct(), let surface, let window else { return }
    let responder = window.firstResponder
    if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView,
      field.isDescendant(of: surface) { return }
    if let view = responder as? NSView, surface.retainsContentFocus(view) { return }
    if let view = responder as? NSView, surface.focusTargets.contains(where: { $0 === view }) { lastFocus = view; return }
    let target = lastFocus.flatMap { previous in surface.focusTargets.first { $0 === previous } }
      ?? surface.initialFocus ?? surface.focusTargets.first
    if let target { window.makeFirstResponder(target); lastFocus = target }
    else { window.makeFirstResponder(nil) }
  }
  @discardableResult func handle(_ event: NSEvent) -> Bool {
    guard canAct(), event.window == nil || event.window === window else { return false }
    containFocus()
    if (window?.firstResponder as? NSTextView)?.hasMarkedText() == true { return false }
    let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
    if (event.keyCode == 53 && flags.isEmpty) || (flags == .command && event.charactersIgnoringModifiers == "w") {
      dismiss(); return true
    }
    if event.keyCode == 48, flags.isEmpty || flags == .shift, let surface {
      let controls = surface.focusTargets; guard !controls.isEmpty else { return true }
      let current = controls.firstIndex { $0 === window?.firstResponder }
      let next = current.map { ($0 + (flags == .shift ? -1 : 1) + controls.count) % controls.count }
        ?? (flags == .shift ? controls.count - 1 : 0)
      window?.makeFirstResponder(controls[next]); lastFocus = controls[next]; return true
    }
    if key(event) { return true }
    return false
  }
  func dismiss() {
    guard canAct(), canDismiss() else { return }; onDismiss(); remove(restore: true)
  }
  private func installMonitor() {
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
      let handled = MainActor.assumeIsolated {
        guard let self, self.window?.isKeyWindow == true, event.window === self.window, self.canAct() else { return false }
        if event.type == .keyDown { return self.handle(event) }; self.containFocus(); return false
      }
      return handled ? nil : event
    }
    for name in [NSWindow.didUpdateNotification, NSWindow.didBecomeKeyNotification] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { if self?.window?.isKeyWindow == true { self?.containFocus() } }
      })
    }
  }
  func remove(restore: Bool) {
    guard let surface else { return }; token = UUID()
    let oldWindow = window, previous = returnView
    surface.active = false; surface.host = nil
    if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
    observers.forEach(NotificationCenter.default.removeObserver); observers = []
    if let oldWindow {
      WindowModalInteraction.remove(surface, from: oldWindow)
      if let focused = oldWindow.firstResponder as? NSView, focused === surface || focused.isDescendant(of: surface) { oldWindow.makeFirstResponder(nil) }
    }
    surface.removeFromSuperview(); self.surface = nil; window = nil; shownIdentity = nil; lastFocus = nil; returnView = nil
    let scheduled = token
    if restore {
      DispatchQueue.main.async { [weak self, weak oldWindow, weak previous] in
        guard let self, self.active, self.token == scheduled, self.identity() == nil,
          let oldWindow, let previous, oldWindow.isKeyWindow, oldWindow.attachedSheet == nil,
          previous.window === oldWindow, !previous.isHiddenOrHasHiddenAncestor, WindowModalInteraction.allows(previous) else { return }
        oldWindow.makeFirstResponder(previous)
      }
    }
  }
  func stop() { remove(restore: false); active = false }
  deinit { if let monitor { NSEvent.removeMonitor(monitor) }; observers.forEach(NotificationCenter.default.removeObserver) }
}
