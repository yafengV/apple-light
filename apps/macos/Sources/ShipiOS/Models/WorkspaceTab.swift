import Foundation

enum WorkspaceTabPlacement: String, Codable, CaseIterable {
  case left
  case right
  case bottom
  case detached

  var label: String {
    switch self {
    case .left: "主内容区"
    case .right: "右侧面板"
    case .bottom: "底部面板"
    case .detached: "新窗口"
    }
  }
}

enum WorkspaceTabDropTarget: Equatable {
  case placement(WorkspaceTabPlacement)
  case newWindow
  case pin
  case chat(String)
  case newChat
}

enum WorkspacePaneSide: String, Codable, CaseIterable {
  case left
  case right

  mutating func swap() {
    self = self == .left ? .right : .left
  }
}

enum WorkspaceTabDragToken {
  private static let prefix = "shipios-workspace-tab-v1:"

  static func encode(_ id: String) -> String { prefix + id }

  static func decode(_ value: String) -> String? {
    guard value.hasPrefix(prefix) else { return nil }
    let id = String(value.dropFirst(prefix.count))
    return id.isEmpty ? nil : id
  }
}

enum WorkspaceContentTab: Hashable, Identifiable {
  case browser(UUID, owner: String)
  case file(String, owner: String)
  case review(owner: String)
  case plan(String, owner: String)
  case sources(owner: String)
  case pullRequest(String, owner: String)
  case pullRequestWatch(UUID, task: String, owner: String)
  case backgroundTerminal(UUID, owner: String)
  case subagents(owner: String)
  case terminal(UUID, owner: String)

  var id: String {
    switch self {
    case .browser(let id, _): "browser:\(id.uuidString)"
    case .file(let path, let owner): "file:\(owner):\(path)"
    case .review(let owner): "review:\(owner)"
    case .plan(let runID, _): "plan:\(runID)"
    case .sources(let owner): "sources:\(owner)"
    case .pullRequest(let url, let owner): "pull-request:\(owner):\(url)"
    case .pullRequestWatch(_, let task, let owner): "pull-request-auto-fix:\(owner):\(task)"
    case .backgroundTerminal(let id, let owner): "background-terminal:\(owner):\(id.uuidString)"
    case .subagents(let owner): "subagents:\(owner)"
    case .terminal(let id, _): "terminal:\(id.uuidString)"
    }
  }

  var owner: String {
    switch self {
    case .browser(_, let owner), .file(_, let owner), .review(let owner), .plan(_, let owner), .sources(let owner), .pullRequest(_, let owner), .pullRequestWatch(_, _, let owner), .terminal(_, let owner), .backgroundTerminal(_, let owner), .subagents(let owner): owner
    }
  }

  var browserID: UUID? {
    guard case .browser(let id, _) = self else { return nil }
    return id
  }

  var backgroundTerminalID: UUID? {
    guard case .backgroundTerminal(let id, _) = self else { return nil }
    return id
  }
  static func backgroundTerminalID(_ tabID: String, owner: String) -> UUID? {
    let prefix = "background-terminal:\(owner):"
    guard tabID.hasPrefix(prefix) else { return nil }
    return UUID(uuidString: String(tabID.dropFirst(prefix.count)))
  }

  var terminalID: UUID? {
    guard case .terminal(let id, _) = self else { return nil }
    return id
  }
  var pullRequestURL: String? {
    guard case .pullRequest(let url, _) = self else { return nil }
    return url
  }
  var watchAutomationID: UUID? {
    guard case .pullRequestWatch(let id, _, _) = self else { return nil }
    return id
  }
  var watchTaskID: String? {
    guard case .pullRequestWatch(_, let task, _) = self else { return nil }
    return task
  }

  var icon: String {
    switch self {
    case .browser: "globe"
    case .file: "doc.text"
    case .review: "square.stack.3d.up"
    case .plan: "text.document"
    case .sources: "square.stack"
    case .pullRequest: "arrow.triangle.pullrequest"
    case .pullRequestWatch: "bolt.horizontal.circle"
    case .backgroundTerminal: "terminal"
    case .subagents: "person.2"
    case .terminal: "terminal"
    }
  }

  var kind: PinnedWorkspaceTabKind {
    switch self {
    case .browser: .browser
    case .file: .file
    case .review: .review
    case .plan: .plan
    case .sources: .sources
    case .pullRequest: .pullRequest
    case .pullRequestWatch: .pullRequestWatch
    case .backgroundTerminal: .backgroundTerminal
    case .subagents: .subagents
    case .terminal: .terminal
    }
  }
}

enum PinnedWorkspaceTabKind: String, Codable {
  case browser
  case file
  case review
  case plan
  case sources
  case pullRequest
  case pullRequestWatch
  case backgroundTerminal
  case subagents
  case terminal
}

/// A durable sidebar reference to one exact task content tab.
///
/// The live content stays with its owning window. The durable reference keeps
/// enough presentation data to restore that source after an app restart without turning it into
/// a project or task pin.
struct PinnedWorkspaceTab: Codable, Equatable, Identifiable {
  var id: String
  var sourceTabID: String
  var owner: String
  var kind: PinnedWorkspaceTabKind
  var title: String
  var restoreURL: String?
  var sourceWindowID: String? = nil
  var fileRoot: String? = nil
  var watchAutomationID: UUID? = nil
  var watchTaskID: String? = nil
  var browserCustomTitle: String? = nil
}
