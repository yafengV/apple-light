import Foundation
import Observation

struct TaskSearchResult: Identifiable, Equatable {
  let task: WorkspaceTask
  let projectTitle: String
  let source: String?
  let snippet: String?
  var id: String { task.id }
}

struct TaskSearchRequest: Equatable {
  let query: String
  let tasks: [WorkspaceTask]
  let names: [String: String]
  let notes: [String: String]
  let branches: [String: String]
  let runs: [AgentRun]
  var includeContentResults = true

  func search() -> [TaskSearchResult] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let matcher = DesktopFuzzyQuery(query)
    let records = Dictionary(runs.map { ($0.id, $0) }, uniquingKeysWith: { first, next in
      next.updatedAt >= first.updatedAt ? next : first
    })
    struct Ranked {
      let result: TaskSearchResult
      let priority: Int
      let score: Int
      let position: Int
    }
    let found: [Ranked] = tasks.enumerated().compactMap { position, task in
      guard !Task.isCancelled, !task.isPopoutDraft else { return nil }
      let project = task.project.isEmpty ? "无项目" : names[task.project] ?? URL(fileURLWithPath: task.project).lastPathComponent
      func result(_ priority: Int, _ score: Int, _ source: String? = nil, _ text: String? = nil) -> Ranked {
        Ranked(result: TaskSearchResult(task: task, projectTitle: project, source: source,
          snippet: text.map { Self.excerpt($0, query: query) }), priority: priority, score: score, position: position)
      }
      if query.isEmpty { return result(0, 0) }
      if let match = matcher.match(task.title) { return result(0, match.score) }
      var branchResult: Ranked?
      func content(_ text: String, source: String) -> Ranked? {
        guard matcher.match(text) != nil else { return nil }
        let snippet = Self.excerpt(text, query: query)
        return result(1, matcher.match(snippet)?.score ?? 1, source, text)
      }
      for id in task.runIDs.reversed() {
        if branchResult == nil, let branch = branches[id], let match = matcher.match(branch) {
          branchResult = result(2, match.score, "分支", branch)
        }
        guard includeContentResults else { continue }
        if let note = notes[id], let hit = content(note, source: "消息") { return hit }
        guard let run = records[id], run.project == task.project else { continue }
        for message in run.codexSteeredMessages {
          if let hit = content(message.text, source: "消息") { return hit }
        }
        if run.kind == "chat", let response = run.result?["response"].text {
          for (_, text) in ConversationSearch.segments(MessageDocument.parse(response)) {
            if let hit = content(text, source: "回答") { return hit }
          }
        } else {
          for text in [run.displaySummary, run.result?["command"]["stdout"].text ?? "",
            run.result?["command"]["stderr"].text ?? ""] {
            if let hit = content(text, source: "执行结果") { return hit }
          }
          for diagnostic in run.result?["command"]["diagnostics"].items ?? [] {
            if let text = diagnostic["message"].text, let hit = content(text, source: "诊断") { return hit }
          }
        }
        if let error = run.result?["message"].text, let hit = content(error, source: "错误") { return hit }
      }
      if query.utf16.count >= 8, task.id.lowercased().hasPrefix(query.lowercased()), let match = matcher.match(task.id) {
        return result(0, match.score)
      }
      if let branchResult { return branchResult }
      if let match = matcher.match(project) { return result(3, match.score) }
      if let match = matcher.match(task.project) { return result(3, match.score) }
      return nil
    }
    if query.isEmpty { return found.map(\.result) }
    return found.sorted {
      if $0.priority != $1.priority { return $0.priority < $1.priority }
      if $0.score != $1.score { return $0.score > $1.score }
      let left = $0.result.task.updatedAt ?? $0.result.task.createdAt ?? .distantPast
      let right = $1.result.task.updatedAt ?? $1.result.task.createdAt ?? .distantPast
      return left == right ? $0.position < $1.position : left > right
    }.map(\.result)
  }

  static func matches(_ text: String, _ query: String) -> Bool {
    DesktopFuzzyQuery(query).match(text) != nil
  }

  static func excerpt(_ text: String, query: String) -> String {
    guard let fragments = DesktopFuzzyQuery(query).match(text)?.ranges,
      let first = fragments.first, let last = fragments.last,
      let match = Range(NSRange(location: first.location, length: NSMaxRange(last) - first.location), in: text)
      else { return String(text.prefix(180)) }
    let start = text.index(match.lowerBound, offsetBy: -55, limitedBy: text.startIndex) ?? text.startIndex
    let end = text.index(match.upperBound, offsetBy: 100, limitedBy: text.endIndex) ?? text.endIndex
    return (start == text.startIndex ? "" : "…") + String(text[start..<end]) + (end == text.endIndex ? "" : "…")
  }

  static func nextSelection(_ current: String?, ids: [String], offset: Int) -> String? {
    guard !ids.isEmpty else { return nil }
    guard let current, let index = ids.firstIndex(of: current) else { return ids.first }
    return ids[max(0, min(ids.count - 1, index + offset))]
  }
}

@MainActor @Observable final class TaskSearchCatalog {
  var history: [AgentRun] = []
  var historyErrors: [String] = []
  var loading = false
  var searching = false
  var results: [TaskSearchResult] = []
  var resultsQuery = ""
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var loadGeneration = UUID()

  func load(root: URL, library: WorkspaceLibrary) async {
    let token = UUID()
    loadGeneration = token
    loading = true
    let job = Task.detached(priority: .userInitiated) {
      TaskSearchHistory.load(root: root, library: library)
    }
    let result = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
    guard !Task.isCancelled, loadGeneration == token else { return }
    history = result.runs
    historyErrors = result.errors
    loading = false
  }

  func search(_ request: TaskSearchRequest) async {
    let token = UUID()
    generation = token
    searching = true
    let job = Task.detached(priority: .userInitiated) { request.search() }
    let found = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
    guard !Task.isCancelled, generation == token else { return }
    results = found
    resultsQuery = request.query
    searching = false
  }
}
