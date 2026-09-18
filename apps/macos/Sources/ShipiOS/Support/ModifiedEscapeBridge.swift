import SwiftUI

/// AppKit does not reliably dispatch modified Escape through SwiftUI menu equivalents.
struct ModifiedEscapeBridge: NSViewRepresentable {
  let store: WorkspaceStore
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    context.coordinator.install(view: view, store: store)
    return view
  }
  func updateNSView(_ view: NSView, context: Context) {}
  static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.stop() }

  final class Coordinator {
    private var monitor: Any?
    func install(view: NSView, store: WorkspaceStore) {
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view, weak store] event in
        MainActor.assumeIsolated {
          guard let window = view?.window, window.isKeyWindow, event.window === window,
            window.attachedSheet == nil, let store, let binding = ShortcutBinding(event: event),
            store.handleModifiedEscape(binding) else { return event }
          return nil
        }
      }
    }
    func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    deinit { stop() }
  }
}

extension WorkspaceStore {
  func handleModifiedEscape(_ binding: ShortcutBinding) -> Bool {
    guard binding.key == "⎋", binding.command || binding.control || binding.option || binding.shift,
      !restoringLibrary, shortcutCaptureCount == 0, presentedOverlay == nil, !hasSettingsConfirmation,
      !showingModelPicker, !showingBranchPicker,
      let command = DesktopCommand.all.first(where: { shortcuts.matches($0.id, binding) })
    else { return false }
    executeCommand(command.id)
    return true
  }
}
