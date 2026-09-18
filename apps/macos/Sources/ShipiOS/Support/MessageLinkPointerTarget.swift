import AppKit
import SwiftUI

/// Intercepts only link-specific modified clicks and context menus. Native Text
/// continues to own ordinary clicks, selection, copying, and accessibility.
struct MessageLinkPointerTarget: NSViewRepresentable {
  let regions: [MessageLinkRegion]
  let actions: MessageLinkActions
  func makeNSView(context: Context) -> TargetView { TargetView() }
  func updateNSView(_ view: TargetView, context: Context) {
    view.regions = regions
    view.actions = actions
    view.setAccessibilityHidden(true)
  }

  final class TargetView: NSView {
    var regions: [MessageLinkRegion] = []
    var actions: MessageLinkActions?
    private var pressed: (url: URL, point: NSPoint, activate: (URL, WebLinkClick) -> Void)?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func link(at point: NSPoint) -> URL? { regions.first { $0.rect.contains(point) }?.url }
    func captures(_ event: NSEvent, at point: NSPoint) -> Bool {
      guard actions != nil, link(at: point) != nil else { return false }
      switch event.type {
      case .rightMouseDown, .rightMouseUp: return true
      case .otherMouseDown, .otherMouseUp, .otherMouseDragged: return event.buttonNumber == 2
      case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
        return !event.modifierFlags.intersection([.command, .control, .option]).isEmpty
      default: return false
      }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
      guard super.hitTest(point) != nil, let event = NSApp.currentEvent else { return nil }
      let local = convert(point, from: superview)
      return captures(event, at: local) ? self : nil
    }
    override func mouseDown(with event: NSEvent) {
      if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
      begin(event)
    }
    override func mouseUp(with event: NSEvent) { finish(event) }
    override func mouseDragged(with event: NSEvent) { cancelAfterDrag(event) }
    override func otherMouseDown(with event: NSEvent) { if event.buttonNumber == 2 { begin(event) } }
    override func otherMouseUp(with event: NSEvent) { if event.buttonNumber == 2 { finish(event) } }
    override func otherMouseDragged(with event: NSEvent) { cancelAfterDrag(event) }

    private func begin(_ event: NSEvent) {
      let point = convert(event.locationInWindow, from: nil)
      guard let actions else { pressed = nil; return }
      pressed = link(at: point).map { ($0, point, actions.activate) }
    }
    private func cancelAfterDrag(_ event: NSEvent) {
      guard let pressed else { return }
      let point = convert(event.locationInWindow, from: nil)
      if hypot(point.x - pressed.point.x, point.y - pressed.point.y) > 4 { self.pressed = nil }
    }
    private func finish(_ event: NSEvent) {
      defer { pressed = nil }
      guard let pressed, link(at: convert(event.locationInWindow, from: nil)) == pressed.url,
        let click = WebLinkClick(event: event) else { return }
      pressed.activate(pressed.url, click)
    }
    override func rightMouseDown(with event: NSEvent) {
      pressed = nil
      guard let url = link(at: convert(event.locationInWindow, from: nil)),
        let menu = menu(for: url) else { return }
      NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    func menu(for url: URL) -> NSMenu? {
      guard let actions else { return nil }
      return MessageLinkMenu.make(url: url, actions: actions)
    }
  }
}

enum MessageLinkMenu {
  static func make(url: URL, actions: MessageLinkActions) -> NSMenu {
    let menu = NSMenu()
    for action in MessageLinkAction.allCases {
      if action == .copy { menu.addItem(.separator()) }
      let target = MenuAction {
        if action == .saveAs {
          DispatchQueue.main.async { actions.perform(url, action) }
        } else { actions.perform(url, action) }
      }
      let item = NSMenuItem(title: action.title, action: #selector(MenuAction.invoke), keyEquivalent: "")
      item.target = target
      item.representedObject = target
      menu.addItem(item)
    }
    return menu
  }
  private final class MenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invoke() { action() }
  }
}
