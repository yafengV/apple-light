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
  case review(owner: String)
  case terminal(UUID, owner: String)

  var id: String {
    switch self {
    case .browser(let id, _): "browser:\(id.uuidString)"
    case .review(let owner): "review:\(owner)"
    case .terminal(let id, _): "terminal:\(id.uuidString)"
    }
  }

  var owner: String {
    switch self {
    case .browser(_, let owner), .review(let owner), .terminal(_, let owner): owner
    }
  }

  var browserID: UUID? {
    guard case .browser(let id, _) = self else { return nil }
    return id
  }

  var terminalID: UUID? {
    guard case .terminal(let id, _) = self else { return nil }
    return id
  }

  var icon: String {
    switch self {
    case .browser: "globe"
    case .review: "square.stack.3d.up"
    case .terminal: "terminal"
    }
  }
}

enum PinnedWorkspaceTabKind: String, Codable {
  case browser
  case review
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
}
