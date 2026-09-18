import SwiftUI

/// Contextual browser shortcuts never consume editing keys outside this browser.
struct BrowserKeyboardBridge: NSViewRepresentable {
  let store: WorkspaceStore
  func makeCoordinator() -> Coordinator { Coordinator(store) }
  func makeNSView(context: Context) -> NSView { NSView() }
  func updateNSView(_ view: NSView, context: Context) {}
  static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.stop() }
  final class Coordinator {
    private var monitor: Any?
    init(_ store: WorkspaceStore) {
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak store] event in
        MainActor.assumeIsolated {
        guard let store, event.window === NSApp?.keyWindow, store.browserFocused,
          let binding = ShortcutBinding(event: event) else { return event }
        if binding == ShortcutBinding("⌘W") {
          store.closeActiveWorkspaceTab(); return nil
        }
        for id in BrowserKeyboardBridge.contextualCommands where store.shortcuts.matches(id, binding) {
          store.performBrowserCommand(id); return nil
        }
        if store.shortcuts.matches("next-task", binding) { store.moveWorkspaceTab(1); return nil }
        if store.shortcuts.matches("previous-task", binding) { store.moveWorkspaceTab(-1); return nil }
        return event
        }
      }
    }
    func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    deinit { stop() }
  }
  static let contextualCommands = ["browser-address", "browser-back", "browser-forward", "browser-reload",
    "browser-reload-origin", "browser-copy", "browser-close"]
}
