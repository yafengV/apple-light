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

  func search() -> [TaskSearchResult] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let records = Dictionary(runs.map { ($0.id, $0) }, uniquingKeysWith: { first, next in
      next.updatedAt >= first.updatedAt ? next : first
    })
    return tasks.compactMap { task in
      guard !Task.isCancelled else { return nil }
      guard !task.isPopoutDraft else { return nil }
      let project = task.project.isEmpty ? "无项目" : names[task.project] ?? URL(fileURLWithPath: task.project).lastPathComponent
      func result(_ source: String? = nil, _ text: String? = nil) -> TaskSearchResult {
        TaskSearchResult(task: task, projectTitle: project, source: source,
          snippet: text.map { Self.excerpt($0, query: query) })
      }
      if query.isEmpty || Self.matches(task.title, query) || Self.matches(project, query) { return result() }
      for id in task.runIDs.reversed() {
        if let branch = branches[id], Self.matches(branch, query) { return result("分支", branch) }
        if let note = notes[id], Self.matches(note, query) { return result("消息", note) }
        guard let run = records[id], run.project == task.project else { continue }
        if run.kind == "chat", let response = run.result?["response"].text {
          // Search displayed text, including code/table cells, rather than Markdown syntax.
          for (_, text) in ConversationSearch.segments(MessageDocument.parse(response)) where Self.matches(text, query) {
            return result("回答", text)
          }
        } else {
          for text in [run.displaySummary, run.result?["command"]["stdout"].text ?? "",
            run.result?["command"]["stderr"].text ?? ""] where Self.matches(text, query) {
            return result("执行结果", text)
          }
          for diagnostic in run.result?["command"]["diagnostics"].items ?? [] {
            if let text = diagnostic["message"].text, Self.matches(text, query) { return result("诊断", text) }
          }
        }
        if let error = run.result?["message"].text, Self.matches(error, query) { return result("错误", error) }
      }
      return nil
    }
  }

  static func matches(_ text: String, _ query: String) -> Bool {
    text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
  }

  static func excerpt(_ text: String, query: String) -> String {
    guard let match = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
      return String(text.prefix(180))
    }
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
