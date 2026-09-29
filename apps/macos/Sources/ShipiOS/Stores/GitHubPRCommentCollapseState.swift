import Observation

/// One Activity surface owns its collapse group; other PR tabs and windows stay independent.
@MainActor @Observable final class GitHubPRCommentCollapseState {
  private struct Entry { var defaultCollapsed: Bool; var collapsed: Bool }
  private var entries: [String: Entry] = [:]

  func preventsCollapse(_ card: GitHubPRCommentCard, drafts: [String: GitHubPRCommentDraft]) -> Bool {
    drafts.contains { id, draft in
      guard card.allIDs.contains(id) else { return false }
      if case .edit = draft.target { return true }
      return !draft.text.isEmpty
    }
  }
  func isCollapsed(_ card: GitHubPRCommentCard, drafts: [String: GitHubPRCommentDraft]) -> Bool {
    if preventsCollapse(card, drafts: drafts) { return false }
    guard let entry = entries[card.id], entry.defaultCollapsed == card.defaultCollapsed else { return card.defaultCollapsed }
    return entry.collapsed
  }
  func sync(_ cards: [GitHubPRCommentCard], drafts: [String: GitHubPRCommentDraft]) {
    let ids = Set(cards.map(\.id)); entries = entries.filter { ids.contains($0.key) }
    for card in cards {
      var entry = entries[card.id] ?? .init(defaultCollapsed: card.defaultCollapsed, collapsed: card.defaultCollapsed)
      if entry.defaultCollapsed != card.defaultCollapsed {
        entry.defaultCollapsed = card.defaultCollapsed; entry.collapsed = card.defaultCollapsed
      }
      if preventsCollapse(card, drafts: drafts) { entry.collapsed = false }
      entries[card.id] = entry
    }
  }
  func expand(_ card: GitHubPRCommentCard) {
    entries[card.id] = .init(defaultCollapsed: card.defaultCollapsed, collapsed: false)
  }
  func toggle(_ card: GitHubPRCommentCard, all: Bool, cards: [GitHubPRCommentCard], drafts: [String: GitHubPRCommentDraft]) {
    let collapse = !isCollapsed(card, drafts: drafts)
    guard !collapse || !preventsCollapse(card, drafts: drafts) else { return }
    for target in all ? cards : [card] {
      guard !collapse || !preventsCollapse(target, drafts: drafts) else { continue }
      entries[target.id] = .init(defaultCollapsed: target.defaultCollapsed, collapsed: collapse)
    }
  }
}
