import Foundation

extension WorkspaceStore {
  var findInputs: [ConversationSearchInput] {
    ConversationSearch.inputs(conversationRuns, library: library)
  }

  var activeFindMatch: ConversationMatch? {
    guard showingFind, indexedFindText == findText, indexedFindTask == selectedTask?.id,
      findMatches.indices.contains(findIndex)
    else {
      return nil
    }
    return findMatches[findIndex]
  }

  func refreshFindMatches() async {
    let token = UUID()
    findGeneration = token
    let query = findText
    let task = selectedTask?.id
    let inputs = findInputs
    let previous = activeFindMatch?.id
    let sameQuery = indexedFindText == query && indexedFindTask == task
    guard !query.isEmpty else {
      findMatches = []
      findIndex = 0
      finding = false
      return
    }
    finding = true
    defer { if findGeneration == token { finding = false } }
    if !sameQuery {
      findMatches = []
      findIndex = 0
    }
    let matches = await Task.detached(priority: .userInitiated) {
      ConversationSearch.find(inputs, query: query)
    }.value
    guard !Task.isCancelled, findGeneration == token,
      findText == query, selectedTask?.id == task
    else { return }
    findMatches = matches
    indexedFindText = query
    indexedFindTask = task
    finding = false
    if sameQuery, let previous, let index = matches.firstIndex(where: { $0.id == previous }) {
      findIndex = index
    } else {
      findIndex = min(findIndex, max(0, matches.count - 1))
      findRequest = UUID()
    }
  }
}
