import AppKit

/// The chat window last used before a modifier-only global Appshot shortcut.
/// Keep its owner window with the draft so capture and the visual handoff agree.
@MainActor enum AppshotShortcutChat {
  case main(NSWindow?)
  case task(String, NSWindow)
  case popout(String, NSWindow)

  static func resolve(lastWindow: NSWindow?, mainWindow: NSWindow?,
    store: WorkspaceStore, popout: PopoutWindowController?) -> Self {
    guard let lastWindow else { return .main(mainWindow) }
    if lastWindow === mainWindow { return .main(mainWindow) }
    if let resources = store.taskWindowResources.allObjects.first(where: {
      $0.window === lastWindow && $0.displayedTaskID != nil
    }), let taskID = resources.displayedTaskID,
      store.library.tasks.contains(where: { $0.id == taskID }) {
      return .task(taskID, lastWindow)
    }
    if let taskID = popout?.activeThreadID(for: lastWindow),
      store.library.tasks.contains(where: { $0.id == taskID }) {
      return .popout(taskID, lastWindow)
    }
    return .main(mainWindow)
  }

  var ownerWindow: NSWindow? {
    switch self {
    case .main(let window): window
    case .task(_, let window), .popout(_, let window): window
    }
  }

  func draftKey(in store: WorkspaceStore) -> String {
    switch self {
    case .main: store.draftKey
    case .task(let taskID, _), .popout(let taskID, _): taskID
    }
  }

  func hasCurrentChat(in store: WorkspaceStore) -> Bool {
    switch self {
    case .main: store.selectedTask != nil
    case .task, .popout: true
    }
  }

  func canAcceptShortcut(in store: WorkspaceStore) -> Bool {
    switch self {
    case .main: store.destination == .workspace && store.action == .chat
    case .task, .popout: true
    }
  }

  func shouldStartNewChat(destination: AppshotDestination, focusedRecently: Bool,
    store: WorkspaceStore) -> Bool {
    destination.shouldStartNewChat(hasCurrentChat: hasCurrentChat(in: store),
      focusedRecently: focusedRecently, canAcceptShortcut: canAcceptShortcut(in: store))
  }
}
