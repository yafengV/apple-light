import SwiftUI

/// Commands about a task are owned by its focused window, never by main selection.
struct TaskWindowCommandContext {
  let enabled: Set<String>
  let perform: (String) -> Void
  var closeTitle: String = "关闭任务窗口"
  var copyLocationTitle: String?
  var keyboardAllowed: (String) -> Bool = { _ in true }
  var recentNavigation: RecentTaskShortcutContext? = nil

  static func owns(_ id: String) -> Bool {
    let taskCommands: Set<String> = [
      "new", "send", "steer-prompt", "queue-prompt", "clear-prompt", "add-photos", "capture-appshot", "add-files", "toggle-worktree-mode", "dictation", "stop", "find", "find-next", "find-previous", "rename", "pin", "unread", "archive",
      "plan", "model", "reasoning-increase", "reasoning-decrease", "reasoning-cycle", "fork", "open-side-chat", "open-task-window", "copy-task-link", "copy-session-id", "copy-conversation-path", "copy-location", "task-summary", "status", "init", "local", "worktree", "doctor", "build", "files", "tree", "review", "review-open",
      "terminal", "bottom-panel", "branch", "sidebar", "tab-close", "tab-close-others",
      "workspace-tabs", "workspace-view", "workspace-swap-panes", "previous-task", "next-task",
      "previous-tab", "next-tab", "previous-recent-task", "next-recent-task",
      "back", "forward", "palette", "search",
    ]
    return taskCommands.contains(id) || DesktopCommand.environmentActionSlot(id) != nil
      || id.hasPrefix("browser-") || id == "browser"
      || DesktopCommand.numberSlot(id) != nil || DesktopCommand.recentChatSlot(id) != nil
  }

  @discardableResult func execute(_ id: String) -> Bool {
    guard Self.owns(id), enabled.contains(id) else { return false }
    perform(id)
    return true
  }

  @MainActor func command(for binding: ShortcutBinding, shortcuts: ShortcutPreferences) -> String? {
    if binding == ShortcutBinding("⌘W") { return "tab-close" }
    return DesktopCommand.all.first { Self.owns($0.id) && shortcuts.matches($0.id, binding)
      && !$0.isTabNavigation && !$0.isRecentTaskNavigation && keyboardAllowed($0.id) }?.id
  }
}

private struct TaskWindowCommandsKey: FocusedValueKey { typealias Value = TaskWindowCommandContext }
extension View {
  @ViewBuilder func backgroundAgentNavigationTitle(_ title: String, embedded: Bool) -> some View {
    if embedded { self }
    else { navigationTitle(title) }
  }
  @ViewBuilder func backgroundAgentCommandRouting(commands: TaskWindowCommandContext,
    embedded: Bool) -> some View {
    if embedded { focusedValue(\.taskWindowCommands, commands) }
    else { focusedSceneValue(\.taskWindowCommands, commands) }
  }
}
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
    context.coordinator.navigationContext = blocked ? nil : commands.recentNavigation
    context.coordinator.shortcuts = shortcuts
    if blocked { context.coordinator.recent.cancel() }
    context.coordinator.handle = { [weak view] binding in
      guard !blocked else { return false }
      if ComposerCommandContext.route(binding, shortcuts: shortcuts, in: view?.window) { return true }
      guard (view?.window?.firstResponder as? NSTextView)?.hasMarkedText() != true else { return false }
      guard let id = commands.command(for: binding, shortcuts: shortcuts) else { return false }
      return commands.execute(id)
    }
  }
  static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.stop() }

  @MainActor final class Coordinator {
    let recent = RecentTaskShortcutController()
    var navigationContext: RecentTaskShortcutContext?
    weak var shortcuts: ShortcutPreferences?
    var handle: ((ShortcutBinding) -> Bool)?
    private var monitor: Any?
    private var observations: [NSObjectProtocol] = []
    func install(_ view: NSView) {
      for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
        observations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self, weak view] note in
          MainActor.assumeIsolated {
            if note.object as? NSWindow === view?.window { self?.recent.cancel() }
          }
        })
      }
      observations.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
        object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.recent.cancel() } })
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self, weak view] event in
        MainActor.assumeIsolated {
          guard let window = view?.window, window.isKeyWindow, (event.window == nil || event.window === window),
            window.attachedSheet == nil, !WindowModalInteraction.blocksCommands(in: window), NSApp.modalWindow == nil else {
            self?.recent.cancel(); return event
          }
          if event.type == .keyDown, (window.firstResponder as? NSTextView)?.hasMarkedText() == true {
            self?.recent.cancel(); return event
          }
          if let self, let shortcuts = self.shortcuts,
            self.recent.handle(event, context: self.navigationContext, shortcuts: shortcuts) { return nil }
          if let self, self.navigationContext != nil, let shortcuts = self.shortcuts,
            RecentTaskShortcutController.isRepeatedAdjacentChat(event, shortcuts: shortcuts) { return nil }
          guard event.type == .keyDown, let binding = ShortcutBinding(event: event) else { return event }
          return self?.handle?(binding) == true ? nil : event
        }
      }
    }
    func stop() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
      handle = nil
      observations.forEach(NotificationCenter.default.removeObserver); observations = []
      recent.cancel(); navigationContext = nil; shortcuts = nil
    }
    deinit { MainActor.assumeIsolated { stop() } }
  }
}
