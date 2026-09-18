import AppKit
import SwiftUI

/// Routes code actions without taking ordinary mouse selection away from the text.
struct CommandClickTarget: NSViewRepresentable {
  var action: () -> Void
  var addComment: () -> Void
  var code: String
  func makeNSView(context: Context) -> TargetView { TargetView() }
  func updateNSView(_ view: TargetView, context: Context) {
    view.action = action
    view.addComment = addComment
    view.code = code
  }

  final class TargetView: NSView {
    var action: (() -> Void)?
    var addComment: (() -> Void)?
    var code = ""
    override func hitTest(_ point: NSPoint) -> NSView? {
      guard let event = NSApp.currentEvent, super.hitTest(point) != nil
      else { return nil }
      let modifiedLeft =
        [.leftMouseDown, .leftMouseUp, .leftMouseDragged].contains(event.type)
        && !event.modifierFlags.intersection([.command, .control]).isEmpty
      let right = [.rightMouseDown, .rightMouseUp].contains(event.type)
      return modifiedLeft || right ? self : nil
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
      if event.modifierFlags.contains(.control) {
        rightMouseDown(with: event)
      } else if event.modifierFlags.contains(.command), event.clickCount == 1 {
        action?()
      }
    }
    override func rightMouseDown(with event: NSEvent) {
      let menu = NSMenu()
      for (title, selector) in [
        ("添加行内评论", #selector(comment)),
        ("在编辑器打开此行", #selector(openLine)),
        ("复制此行", #selector(copyLine)),
      ] {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
      }
      NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    @objc private func comment() { addComment?() }
    @objc private func openLine() { action?() }
    @objc private func copyLine() {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(code, forType: .string)
    }
  }
}
