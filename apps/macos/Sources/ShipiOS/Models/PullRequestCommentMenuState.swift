import Foundation
import Observation

enum PullRequestCommentMenuAction: String, CaseIterable, Identifiable {
  case edit, quote, delete
  var id: String { rawValue }
  var title: String { switch self { case .edit: "编辑"; case .quote: "引用回复"; case .delete: "删除" } }
  static func options(_ comment: GitHubPRComment, thread: GitHubPRReviewThread?, isReply: Bool) -> [Self] {
    allCases.filter {
      switch $0 {
      case .edit: comment.canUpdate
      case .quote: !isReply && (thread == nil || thread?.canReply == true)
      case .delete: comment.canDelete
      }
    }
  }
}

@MainActor @Observable final class PullRequestCommentMenuState: SettingsPopupMenuState {
  private(set) var presented = false
  private(set) var options: [PullRequestCommentMenuAction] = []
  var highlightedID: String?
  private var search = ""
  private var lastTypedAt: TimeInterval?
  init(options: [PullRequestCommentMenuAction] = []) { self.options = options }
  func configure(_ options: [PullRequestCommentMenuAction]) {
    self.options = options
    if options.isEmpty { dismiss() }
    else if let highlightedID, !options.contains(where: { $0.id == highlightedID }) { self.highlightedID = options.first?.id }
  }
  func open(keyboard: Bool) {
    guard !options.isEmpty else { return }
    presented = true; highlightedID = keyboard ? options.first?.id : nil; search = ""; lastTypedAt = nil
  }
  func dismiss() { presented = false; highlightedID = nil; search = ""; lastTypedAt = nil }
  func move(_ delta: Int) {
    guard presented, !options.isEmpty else { return }
    let index = options.firstIndex { $0.id == highlightedID }
    highlightedID = options[index.map { max(0, min(options.count - 1, $0 + delta)) } ?? (delta < 0 ? options.count - 1 : 0)].id
  }
  func edge(last: Bool) { guard presented else { return }; highlightedID = last ? options.last?.id : options.first?.id }
  func hover(_ id: String?) {
    guard presented, id == nil || options.contains(where: { $0.id == id }) else { return }; highlightedID = id
  }
  func type(_ character: String, now: TimeInterval) {
    guard presented else { return }
    if lastTypedAt.map({ now - $0 >= 1 }) != false { search = "" }
    search += character; lastTypedAt = now
    let chars = Array(search), pattern = chars.count > 1 && chars.allSatisfy({ $0 == chars.first }) ? String(chars[0]) : search
    let start = options.firstIndex { $0.id == highlightedID } ?? 0
    let candidates = (0..<options.count).map { options[($0 + start) % options.count] }
    if let match = candidates.first(where: { !(pattern.utf16.count == 1 && $0.id == highlightedID) && $0.title.hasPrefix(pattern) }) {
      highlightedID = match.id
    }
  }
  func space(now: TimeInterval) -> Bool {
    guard presented else { return false }
    if !search.isEmpty, lastTypedAt.map({ now - $0 < 1 }) == true { type(" ", now: now); return false }; return true
  }
}
