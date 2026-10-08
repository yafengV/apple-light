import AppKit

@MainActor struct RecentTaskShortcutContext {
  var currentID: String?
  var recentIDs: [String]
  var isAvailable: (String) -> Bool
  var title: (String) -> String
  var select: (String) -> Void
  var claimsTabs: () -> Bool = { false }
  var selectTab: (Int) -> Bool = { _ in false }
}

/// Each native window owns its pending selection. No navigation or visit write
/// occurs until a triggering Control/Command/Option (or unmodified key) lifts.
@MainActor final class RecentTaskShortcutController {
  private(set) var session: RecentTaskSelection?
  private var releaseModifiers: NSEvent.ModifierFlags = []
  private var releaseKeyCode: UInt16?
  private var originID: String?
  var announce: (String) -> Void = { text in
    NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
      userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
  }

  @discardableResult func handle(_ event: NSEvent, context: RecentTaskShortcutContext?,
    shortcuts: ShortcutPreferences) -> Bool {
    guard let context else { cancel(); return false }
    if session != nil, originID != context.currentID { cancel() }
    if event.type == .flagsChanged {
      if session != nil, !releaseModifiers.isEmpty,
        !event.modifierFlags.isSuperset(of: releaseModifiers) { commit(context) }
      return false
    }
    if event.type == .keyUp {
      if session != nil, releaseModifiers.isEmpty, releaseKeyCode == event.keyCode { commit(context) }
      return false
    }
    guard event.type == .keyDown, let binding = ShortcutBinding(event: event) else { return false }
    for (id, direction) in [("next-tab", 1), ("previous-tab", -1)]
      where shortcuts.matches(id, binding) && context.claimsTabs() {
      if context.selectTab(direction) { cancel(); return true }
    }
    let direction: Int
    if shortcuts.matches("next-recent-task", binding) { direction = 1 }
    else if shortcuts.matches("previous-recent-task", binding) { direction = -1 }
    else { return false }
    if session == nil {
      originID = context.currentID
      releaseModifiers = event.modifierFlags.intersection([.control, .command, .option])
      releaseKeyCode = event.keyCode
    }
    session = RecentTaskSelection.step(current: context.currentID, direction: direction,
      recent: context.recentIDs, session: session, isAvailable: context.isAvailable)
    if let session, let id = session.selectedID, context.isAvailable(id) {
      let title = context.title(id)
      announce("\(title.isEmpty ? "未命名任务" : title)，第 \(session.selectedIndex + 1) 项，共 \(session.threadKeys.count) 项")
    }
    return true
  }

  static func isRepeatedAdjacentChat(_ event: NSEvent, shortcuts: ShortcutPreferences) -> Bool {
    guard event.type == .keyDown, event.isARepeat, let binding = ShortcutBinding(event: event) else { return false }
    return ["next-task", "previous-task"].contains { shortcuts.matches($0, binding) }
  }

  func cancel() {
    session = nil; releaseModifiers = []; releaseKeyCode = nil; originID = nil
  }
  private func commit(_ context: RecentTaskShortcutContext) {
    let id = session?.selectedID
    cancel()
    if let id, id != context.currentID, context.isAvailable(id) { context.select(id) }
  }
}
