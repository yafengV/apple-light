import AppKit
import SwiftUI
import SwiftTerm
import WebKit

/// Plain Return/Escape must not become app-wide menu key equivalents: a hidden
/// task's pending request must never consume text input or another window's keys.
struct MCPApprovalKeyboardBridge: NSViewRepresentable {
  let store: WorkspaceStore
  let taskID: String?
  let visible: Bool

  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    context.coordinator.install(view: view)
    updateNSView(view, context: context)
    return view
  }
  func updateNSView(_ view: NSView, context: Context) {
    context.coordinator.handle = { [weak store] binding, flags in
      var flags = flags
      flags.visible = visible
      return store?.handleMCPApprovalShortcut(binding, taskID: taskID, context: flags) ?? false
    }
  }
  static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.stop() }

  final class Coordinator {
    var handle: ((ShortcutBinding, MCPApprovalKeyContext) -> Bool)?
    private var monitor: Any?
    func install(view: NSView) {
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak view] event in
        MainActor.assumeIsolated {
          guard let window = view?.window, window.isKeyWindow, event.window === window,
            let binding = ShortcutBinding(event: event) else { return event }
          let editor = window.firstResponder as? NSTextView
          var panelInput = false
          var ancestor = window.firstResponder as? NSView
          while let item = ancestor {
            if item is TerminalView || item is WKWebView || item is NSTableView || item is NSOutlineView {
              panelInput = true; break
            }
            ancestor = item.superview
          }
          let flags = MCPApprovalKeyContext(hasSheet: window.attachedSheet != nil,
            isRepeat: event.isARepeat, editingText: editor?.isEditable == true,
            markedText: editor?.hasMarkedText() == true, ownsPanelInput: panelInput)
          return self?.handle?(binding, flags) == true ? nil : event
        }
      }
    }
    func stop() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil; handle = nil
    }
    deinit { stop() }
  }
}

/// Focus the SwiftUI approval button only when its window is active and the user
/// is not drafting or working in a different input surface.
struct MCPApprovalFocusBridge: NSViewRepresentable {
  let pending: Bool
  let focus: () -> Void
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSView { NSView() }
  func updateNSView(_ view: NSView, context: Context) {
    guard pending != context.coordinator.pending else { return }
    context.coordinator.pending = pending
    guard pending else { return }
    DispatchQueue.main.async { [weak view] in
      guard let window = view?.window, window.isKeyWindow, window.attachedSheet == nil,
        context.coordinator.pending else { return }
      if let composer = window.firstResponder as? ComposerNativeTextView {
        guard composer.string.isEmpty, !composer.hasMarkedText() else { return }
      } else if window.firstResponder is NSTextView || window.firstResponder is NSControl {
        return
      } else if window.firstResponder is NSView {
        // Preserve panel and browser focus. Initial window focus may be nil.
        return
      }
      focus()
    }
  }
  final class Coordinator { var pending = false }
}
