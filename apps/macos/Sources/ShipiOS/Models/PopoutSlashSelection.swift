import Foundation

enum PopoutSlashItem: Hashable {
  case new
  case resume
  case task(String)
  case empty
}

struct PopoutSlashSelection {
  enum Key { case previous, next, accept, dismiss }
  enum Result: Equatable { case ignored, handled, accept(PopoutSlashItem) }
  enum Stage: Equatable { case commands, recent }

  private(set) var stage: Stage = .commands
  private(set) var items: [PopoutSlashItem] = []
  private(set) var selected: PopoutSlashItem?
  private(set) var recentTasks: [WorkspaceTask] = []
  private var draft = ""
  private var dismissed = false
  private var commandItems: [PopoutSlashItem] = []
  var isVisible: Bool { !dismissed && !items.isEmpty }

  mutating func update(draft: String, canNew: Bool, tasks: [WorkspaceTask],
    currentTaskID: String?, hasAttachments: Bool) {
    if draft != self.draft {
      self.draft = draft
      stage = .commands
      selected = nil
      dismissed = false
    }
    recentTasks = Self.recentTasks(tasks, excluding: currentTaskID)
    guard !hasAttachments, draft.hasPrefix("/"),
      !draft.contains(where: \.isWhitespace) else {
      items = []
      selected = nil
      return
    }
    commandItems = (canNew ? [.new, .resume] : [.resume]).filter { item in
      switch item {
      case .new: "/new".hasPrefix(draft.lowercased())
      case .resume: "/resume".hasPrefix(draft.lowercased())
      default: false
      }
    }
    switch stage {
    case .commands:
      items = commandItems
    case .recent:
      items = recentTasks.isEmpty ? [.empty] : recentTasks.map { .task($0.id) }
    }
    if let selected, items.contains(selected) { return }
    selected = items.first { $0 != .empty }
  }

  mutating func highlight(_ item: PopoutSlashItem) {
    guard items.contains(item), item != .empty else { return }
    selected = item
  }

  mutating func handle(_ key: Key, isComposing: Bool = false) -> Result {
    guard isVisible, !isComposing else { return .ignored }
    switch key {
    case .dismiss:
      if stage == .recent {
        stage = .commands
        items = commandItems
        selected = .resume
      } else {
        dismissed = true
      }
      return .handled
    case .previous, .next:
      let choices = items.filter { $0 != .empty }
      guard !choices.isEmpty else { return .handled }
      let index = selected.flatMap { choices.firstIndex(of: $0) } ?? 0
      selected = choices[min(max(index + (key == .next ? 1 : -1), 0), choices.count - 1)]
      return .handled
    case .accept:
      guard let selected else { return .handled }
      if selected == .resume {
        stage = .recent
        items = recentTasks.isEmpty ? [.empty] : recentTasks.map { .task($0.id) }
        self.selected = items.first { $0 != .empty }
        return .handled
      }
      return .accept(selected)
    }
  }

  static func recentTasks(_ tasks: [WorkspaceTask], excluding currentTaskID: String?)
    -> [WorkspaceTask] {
    Array(tasks.filter {
      !$0.archived && !$0.isTransient && $0.id != currentTaskID
    }.sorted {
      let lhs = $0.updatedAt ?? $0.createdAt ?? .distantPast
      let rhs = $1.updatedAt ?? $1.createdAt ?? .distantPast
      return lhs == rhs ? $0.id < $1.id : lhs > rhs
    }.prefix(20))
  }
}
