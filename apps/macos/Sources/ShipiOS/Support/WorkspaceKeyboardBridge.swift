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
  func updateNSView(_ view: NSView, context: Context) {
    if store.taskNavigationShortcutContext == nil { context.coordinator.recent.cancel() }
  }
  static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.stop() }

  @MainActor final class Coordinator {
    let recent = RecentTaskShortcutController()
    private var monitor: Any?
    private var observations: [NSObjectProtocol] = []
    func install(_ view: NSView, store: WorkspaceStore) {
      for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
        observations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self, weak view] note in
          MainActor.assumeIsolated {
            if note.object as? NSWindow === view?.window { self?.recent.cancel() }
          }
        })
      }
      observations.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
        object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.recent.cancel() } })
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self, weak view, weak store] event in
        MainActor.assumeIsolated {
          guard let window = view?.window, window.isKeyWindow,
            event.window == nil || event.window === window,
            window.attachedSheet == nil, NSApp.modalWindow == nil, !WindowModalInteraction.blocksCommands(in: window), let store else {
            self?.recent.cancel(); return event
          }
          if event.type == .keyDown, (window.firstResponder as? NSTextView)?.hasMarkedText() == true {
            self?.recent.cancel(); return event
          }
          if self?.recent.handle(event, context: store.taskNavigationShortcutContext, shortcuts: store.shortcuts) == true { return nil }
          if store.taskNavigationShortcutContext != nil,
            RecentTaskShortcutController.isRepeatedAdjacentChat(event, shortcuts: store.shortcuts) { return nil }
          guard event.type == .keyDown else { return event }
          if event.keyCode == 53,
            event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
            store.closeSettingsFromKeyboard(in: window) { return nil }
          guard let binding = ShortcutBinding(event: event) else { return event }
          guard store.handleWorkspaceShortcut(binding, in: window) else { return event }
          return nil
        }
      }
    }
    func stop() {
      if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
      observations.forEach(NotificationCenter.default.removeObserver); observations = []
      recent.cancel()
    }
    deinit { MainActor.assumeIsolated { stop() } }
  }
}

extension WorkspaceStore {
  func handleWorkspaceShortcut(_ binding: ShortcutBinding, in window: NSWindow?) -> Bool {
    if destination == .workspace, !libraryRecoveryBlocksInteraction, !showingModelPicker,
      !showingBranchPicker, presentedOverlay == nil, !hasSettingsConfirmation,
      shortcutCaptureCount == 0,
      ComposerCommandContext.route(binding, shortcuts: shortcuts, in: window) { return true }
    return handleWorkspaceShortcut(binding)
  }

  func handleWorkspaceShortcut(_ binding: ShortcutBinding) -> Bool {
    guard !libraryRecoveryBlocksInteraction, shortcutCaptureCount == 0, presentedOverlay == nil, !hasSettingsConfirmation,
      !showingModelPicker, !showingBranchPicker else { return false }
    if destination == .settings, settingsPage == .personalization,
      binding == ShortcutBinding("⌘S"), canSavePersonalizationEdits {
      // Consume a failed save too: preserve the draft and show its error instead
      // of falling through to an unrelated command or native save panel.
      savePersonalizationEdits()
      return true
    }
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
        !$0.allowsBareModifiers && !$0.isRecentTaskNavigation && !$0.isTabNavigation
          && !BrowserKeyboardBridge.contextualCommands.contains($0.id)
          && !["approval-approve", "approval-decline"].contains($0.id)
          && ((["tree", "review", "review-open", "tab-close", "tab-close-others",
            "workspace-view", "workspace-tabs", "workspace-swap-panes"].contains($0.id)
              || DesktopCommand.numberSlot($0.id) != nil) && shortcuts.matches($0.id, binding)
            || shortcuts.bindings($0.id).dropFirst().contains(binding))
      }), commandEnabled(command.id) else { return false }
    if (command.id == "back" || command.id == "forward"), workspace.browser.hasEditableFocus { return false }
    executeCommand(command.id)
    return true
  }
}
