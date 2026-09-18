import SwiftUI

/// Commands about a task are owned by its focused window, never by main selection.
struct TaskWindowCommandContext {
  let enabled: Set<String>
  let perform: (String) -> Void

  static func owns(_ id: String) -> Bool {
    let taskCommands: Set<String> = [
      "send", "stop", "find", "find-next", "find-previous", "rename", "pin", "unread", "archive",
      "plan", "model", "fork", "doctor", "build", "files", "tree", "review", "review-open",
      "terminal", "bottom-panel", "branch", "sidebar", "tab-close", "tab-close-others",
      "workspace-tabs", "workspace-view", "workspace-swap-panes", "previous-task", "next-task",
      "back", "forward",
    ]
    return taskCommands.contains(id) || id.hasPrefix("browser-") || id == "browser"
      || DesktopCommand.numberSlot(id) != nil
  }

  @discardableResult func execute(_ id: String) -> Bool {
    guard Self.owns(id), enabled.contains(id) else { return false }
    perform(id)
    return true
  }

  @MainActor func command(for binding: ShortcutBinding, shortcuts: ShortcutPreferences) -> String? {
    if binding == ShortcutBinding("⌘W") { return "tab-close" }
    return DesktopCommand.all.first { Self.owns($0.id) && shortcuts.matches($0.id, binding) }?.id
  }
}

private struct TaskWindowCommandsKey: FocusedValueKey { typealias Value = TaskWindowCommandContext }
extension FocusedValues {
  var taskWindowCommands: TaskWindowCommandContext? {
    get { self[TaskWindowCommandsKey.self] }
    set { self[TaskWindowCommandsKey.self] = newValue }
  }
}

struct TaskWindowCommandKeyboardBridge: NSViewRepresentable {
  let commands: TaskWindowCommandContext
  let shortcuts: ShortcutPreferences
  let blocked: Bool

  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    context.coordinator.install(view)
    return view
  }
  func updateNSView(_ view: NSView, context: Context) {
    context.coordinator.handle = { binding in
      guard !blocked, let id = commands.command(for: binding, shortcuts: shortcuts) else { return false }
      return commands.execute(id)
    }
  }
  static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.stop() }

  final class Coordinator {
    var handle: ((ShortcutBinding) -> Bool)?
    private var monitor: Any?
    func install(_ view: NSView) {
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak view] event in
        MainActor.assumeIsolated {
          guard let window = view?.window, window.isKeyWindow, event.window === window,
            window.attachedSheet == nil, NSApp.modalWindow == nil,
            (window.firstResponder as? NSTextView)?.hasMarkedText() != true,
            let binding = ShortcutBinding(event: event) else { return event }
          return self?.handle?(binding) == true ? nil : event
        }
      }
    }
    func stop() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
      handle = nil
    }
    deinit { stop() }
  }
}
