import Foundation

enum TaskSummarySource: Identifiable, Equatable {
  case file(FileAttachment)
  case image(ImageAttachment)
  case external(CodexWebSource)
  case siteTool(MCPToolExecution)
  case tool(id: UUID, name: String)
  case webSearch(CodexWebSearchSummary)

  var id: String {
    switch self {
    case .file(let file): "file:\(file.id.uuidString)"
    case .image(let image): "image:\(image.id.uuidString)"
    case .external(let source): "external:\(source.url)"
    case .siteTool(let execution): "site-tool:\(execution.id.uuidString)"
    case .tool(let id, _): "tool:\(id.uuidString)"
    case .webSearch: "web-search"
    }
  }

  var title: String {
    switch self {
    case .file(let file): file.name
    case .image(let image): image.name
    case .external(let source): source.title
    case .siteTool(let execution): execution.browserSiteTool?.name ?? execution.toolName
    case .tool(_, let name): name
    case .webSearch: "网页搜索"
    }
  }

  var searchableText: String {
    if case .external(let source) = self { return source.title + " " + source.url }
    if case .siteTool(let execution) = self {
      guard let activity = execution.browserSiteTool else { return execution.toolName }
      return activity.name + " " + activity.title + " " + activity.url
    }
    if case .webSearch(let summary) = self {
      return ([title] + summary.queries + summary.viewedLinks.flatMap { [$0.title, $0.url] })
        .joined(separator: " ")
    }
    return title
  }
}

struct CodexWebSearchSummary: Equatable {
  var queryCount = 0
  var queries: [String] = []
  var viewedLinks: [CodexWebSource] = []

  mutating func add(_ activity: CodexWebSearchActivity, seenQueries: inout Set<String>,
    seenLinks: inout Set<String>) {
    queryCount += activity.queryCount
    for query in activity.queries where seenQueries.insert(query).inserted { queries.append(query) }
    for link in activity.viewedLinks where seenLinks.insert(link.url).inserted { viewedLinks.append(link) }
  }
}

extension Collection where Element == AgentRun {
  func summarySources(in library: WorkspaceLibrary) -> [TaskSummarySource] {
    var files: [TaskSummarySource] = []
    var external: [TaskSummarySource] = []
    var tools: [TaskSummarySource] = []
    var seen = Set<String>()
    var webSearch: CodexWebSearchSummary?
    var seenQueries = Set<String>()
    var seenLinks = Set<String>()
    for run in self {
      for file in library.runFiles[run.id] ?? [] {
        let source = TaskSummarySource.file(file)
        if seen.insert(source.id).inserted { files.append(source) }
      }
      for image in library.runImages[run.id] ?? [] {
        let source = TaskSummarySource.image(image)
        if seen.insert(source.id).inserted { files.append(source) }
      }
      for webSource in run.codexWebSources {
        guard (webSource.url.hasPrefix("https://") || webSource.url.hasPrefix("http://")),
          (try? BrowserAddress.url(webSource.url)) != nil else { continue }
        let source = TaskSummarySource.external(webSource)
        if seen.insert(source.id).inserted { external.append(source) }
      }
      for execution in run.toolExecutions {
        if execution.serverID == CodexBrowserTimeline.serverID,
          execution.status == .succeeded, execution.browserSiteTool != nil {
          let source = TaskSummarySource.siteTool(execution)
          if seen.insert(source.id).inserted { tools.append(source) }
        } else if execution.serverID == CodexWebSearchTimeline.serverID {
          if execution.status == .succeeded {
            if webSearch == nil { webSearch = CodexWebSearchSummary() }
            webSearch?.add(execution.webSearchActivity ?? .legacy(execution),
              seenQueries: &seenQueries, seenLinks: &seenLinks)
          }
        } else if execution.serverID != CodexCommandTimeline.serverID
          && execution.serverID != CodexBrowserTimeline.serverID,
          !execution.serverName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          let source = TaskSummarySource.tool(id: execution.serverID, name: execution.serverName)
          if seen.insert(source.id).inserted { tools.append(source) }
        }
      }
    }
    return files + external + tools + (webSearch.map { [.webSearch($0)] } ?? [])
  }
}
