import Foundation

extension WorkspaceStore {
  func conversationRailItems(for runs: [AgentRun]) -> [ConversationRailItem] {
    runs.flatMap { run -> [ConversationRailItem] in
      let prompt = library.notes[run.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
      let fallback = library.runFiles[run.id]?.first?.name
        ?? (library.runImages[run.id]?.isEmpty == false ? "图片" : run.title)
      let preview = prompt.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
      let first = ConversationRailItem(id: run.id, title: run.title, preview: preview,
        date: run.date, bookmarked: library.bookmarkedRunIDs.contains(run.id))
      let messages = Dictionary(run.codexSteeredMessages.map { ($0.id, $0) },
        uniquingKeysWith: { first, _ in first })
      let steered = (run.responseItems ?? run.displayedResponseItems).compactMap { item -> ConversationRailItem? in
        guard case .user(let id) = item, let message = messages[id] else { return nil }
        let key = ConversationRailItem.steeredID(runID: run.id, messageID: id)
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = text.isEmpty ? (message.files.first?.name ?? (message.images.isEmpty ? "消息" : "图片")) : text
        return ConversationRailItem(id: key, title: "追加消息", preview: preview,
          date: run.date, bookmarked: library.bookmarkedRunIDs.contains(key))
      }
      return [first] + steered
    }
  }

  @discardableResult func setConversationBookmark(_ bookmarked: Bool, runID: String) -> Bool {
    guard libraryLoaded else { return false }
    let allRuns = runs + library.localRuns
    let known = allRuns.contains { run in
      run.id == runID || run.codexSteeredMessages.contains {
        ConversationRailItem.steeredID(runID: run.id, messageID: $0.id) == runID
      }
    }
    guard known else { return false }
    var candidate = library
    if bookmarked { candidate.bookmarkedRunIDs.insert(runID) }
    else { candidate.bookmarkedRunIDs.remove(runID) }
    guard candidate.bookmarkedRunIDs != library.bookmarkedRunIDs else { return true }
    do {
      try commitLibrary(candidate)
      return true
    } catch {
      self.error = "无法保存消息书签：\(error.localizedDescription)"
      return false
    }
  }
}
