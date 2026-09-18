import SwiftUI

/// SwiftUI menus expose one key equivalent. Route additional bindings and
/// panel commands that native editing menu equivalents would otherwise consume.
struct WorkspaceKeyboardBridge: NSViewRepresentable {
  let store: WorkspaceStore
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    context.coordinator.install(view, store: store)
    return view
  }
  func updateNSView(_ view: NSView, context: Context) {}
  static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.stop() }

  final class Coordinator {
    private var monitor: Any?
    func install(_ view: NSView, store: WorkspaceStore) {
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view, weak store] event in
        MainActor.assumeIsolated {
          guard let window = view?.window, window.isKeyWindow, event.window === window,
            window.attachedSheet == nil, let store, let binding = ShortcutBinding(event: event),
            store.handleWorkspaceShortcut(binding) else { return event }
          return nil
        }
      }
    }
    func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    deinit { stop() }
  }
}

extension WorkspaceStore {
  func handleWorkspaceShortcut(_ binding: ShortcutBinding) -> Bool {
    guard !restoringLibrary, shortcutCaptureCount == 0, presentedOverlay == nil, !hasSettingsConfirmation,
      !showingModelPicker, !showingBranchPicker else { return false }
    if destination == .settings, shortcuts.matches("find", binding) {
      executeCommand("find")
      return true
    }
    if binding == ShortcutBinding("⌘W"), commandEnabled("tab-close") {
      executeCommand("tab-close")
      return true
    }
    guard
      let command = DesktopCommand.all.first(where: {
        !BrowserKeyboardBridge.contextualCommands.contains($0.id)
          && !["approval-approve", "approval-decline"].contains($0.id)
          && ((["tree", "review", "review-open", "tab-close", "tab-close-others",
            "workspace-view", "workspace-tabs", "workspace-swap-panes"].contains($0.id)
              || DesktopCommand.numberSlot($0.id) != nil) && shortcuts.matches($0.id, binding)
            || shortcuts.bindings($0.id).dropFirst().contains(binding))
      }), commandEnabled(command.id) else { return false }
    executeCommand(command.id)
    return true
  }
}
