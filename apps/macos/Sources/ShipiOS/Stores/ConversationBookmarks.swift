import Foundation

extension WorkspaceStore {
  func conversationRailItems(for runs: [AgentRun]) -> [ConversationRailItem] {
    runs.flatMap { run -> [ConversationRailItem] in
      let prompt = library.notes[run.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
      let fallback = library.runFiles[run.id]?.first?.name
        ?? (library.runImages[run.id]?.isEmpty == false ? "图片" : run.title)
      var title = prompt.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
      var id = run.id
      var response: [String] = []
      var outputs: [ConversationRailItem.Output] = []
      var additionalOutputCount = 0
      var items: [ConversationRailItem] = []
      let bookmarkedIDs = library.bookmarkedRunIDs
      let executions = Dictionary(run.toolExecutions.map { ($0.id, $0) },
        uniquingKeysWith: { first, _ in first })
      let messages = Dictionary(run.codexSteeredMessages.map { ($0.id, $0) },
        uniquingKeysWith: { first, _ in first })
      func finish(last: Bool) -> ConversationRailItem {
        let preview = response.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return ConversationRailItem(id: id, title: title, preview: preview,
          date: run.date, bookmarked: bookmarkedIDs.contains(id),
          previewState: last && run.isActive && preview.isEmpty ? .loading : .ready,
          outputs: outputs, additionalOutputCount: additionalOutputCount)
      }
      if run.kind == "chat" {
        for item in run.responseItems ?? run.displayedResponseItems {
          switch item {
          case .message(_, let text):
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              response.append(text)
            }
          case .user(let messageID):
            guard let message = messages[messageID] else { continue }
            items.append(finish(last: false))
            id = ConversationRailItem.steeredID(runID: run.id, messageID: messageID)
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            title = text.isEmpty
              ? (message.files.first?.name ?? (message.images.isEmpty ? "(无内容)" : "图片"))
              : text
            response = []
            outputs = []
            additionalOutputCount = 0
          case .diff(let diffID):
            // A turn diff is cumulative. With steering, its final file set cannot
            // reliably be assigned to one user message.
            guard messages.isEmpty, let diff = run.codexTurnDiff,
              diff.id == diffID else { continue }
            let files = CodexTurnDiffFiles.parse(diff.unifiedDiff)
            for file in files {
              let outputID = "file:\(file.path)"
              guard !outputs.contains(where: { $0.id == outputID }) else { continue }
              outputs.append(.init(id: outputID, label: file.path, kind: .file))
            }
            additionalOutputCount = max(0, diff.changedFileCount - files.count)
          case .tool(let executionID):
            guard let execution = executions[executionID],
              execution.status == .succeeded else { continue }
            for activity in execution.mcpResourceActivities
              ?? MCPResourceActivity.restored(from: execution.output) ?? []
            where activity.activities.contains(.created) || activity.activities.contains(.updated) {
              let source = activity.source
              let outputID = "external:\(source.url)"
              guard !outputs.contains(where: { $0.id == outputID }) else { continue }
              let kind: ConversationRailItem.Output.Kind = activity.mimeType?.hasPrefix("image/") == true
                ? .image : .website
              outputs.append(.init(id: outputID, label: source.title, kind: kind))
            }
          default: break
          }
        }
      } else {
        response = [run.displaySummary]
      }
      items.append(finish(last: true))
      return items
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
