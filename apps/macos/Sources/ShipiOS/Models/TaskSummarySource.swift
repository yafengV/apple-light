import Foundation

enum TaskSummarySource: Identifiable, Equatable {
  case file(FileAttachment)
  case image(ImageAttachment)
  case external(TaskExternalSource)
  case siteTool(MCPToolExecution)
  case tool(MCPToolSource)
  case webSearch(CodexWebSearchSummary)

  var id: String {
    switch self {
    case .file(let file): "file:\(file.id.uuidString)"
    case .image(let image): "image:\(image.id.uuidString)"
    case .external(let source): "external:\(source.id)"
    case .siteTool(let execution): "site-tool:\(execution.id.uuidString)"
    case .tool(let source): "tool:\(source.id.uuidString)"
    case .webSearch: "web-search"
    }
  }

  var title: String {
    switch self {
    case .file(let file): file.name
    case .image(let image): image.name
    case .external(let source): source.title
    case .siteTool(let execution): execution.browserSiteTool?.name ?? execution.toolName
    case .tool(let source): source.name
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
    if case .tool(let source) = self {
      return ([source.name] + source.activities.map(\.name)).joined(separator: " ")
    }
    return title
  }
}

struct MCPToolSource: Identifiable, Equatable {
  let id: UUID
  let name: String
  var calls: [MCPToolExecution]

  var activities: [MCPToolActivity] {
    var groups: [MCPToolActivity] = []
    for call in calls {
      if let index = groups.firstIndex(where: { $0.name == call.toolName }) {
        groups[index].calls.append(call)
      } else {
        groups.append(MCPToolActivity(name: call.toolName, calls: [call]))
      }
    }
    return groups
  }
}

struct MCPToolActivity: Identifiable, Equatable {
  let name: String
  var calls: [MCPToolExecution]
  var id: String { name }
}

struct CodexWebSearchSummary: Equatable {
  var queryCount = 0
  var queries: [String] = []
  var viewedLinks: [CodexWebSource] = []

  mutating func add(_ activity: CodexWebSearchActivity, seenQueries: inout Set<String>,
    seenLinks: inout Set<String>) {
    queryCount += activity.queryCount
    for query in activity.queries where seenQueries.insert(query).inserted { queries.append(query) }
    for link in activity.viewedLinks
      where seenLinks.insert(CodexWebSource.sourceKey(link.url) ?? link.url).inserted {
      viewedLinks.append(link)
    }
  }
}

extension Collection where Element == AgentRun {
  func summarySources(in library: WorkspaceLibrary) -> [TaskSummarySource] {
    var files: [TaskSummarySource] = []
    var toolSources: [MCPToolSource] = []
    var siteTools: [TaskSummarySource] = []
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
      if run.kind == "chat" {
        for message in run.codexSteeredMessages {
          for file in message.files {
            let source = TaskSummarySource.file(file)
            if seen.insert(source.id).inserted { files.append(source) }
          }
          for image in message.images {
            let source = TaskSummarySource.image(image)
            if seen.insert(source.id).inserted { files.append(source) }
          }
        }
      }
      for execution in run.toolExecutions {
        if execution.serverID == CodexBrowserTimeline.serverID,
          execution.status == .succeeded, execution.browserSiteTool != nil {
          let source = TaskSummarySource.siteTool(execution)
          if seen.insert(source.id).inserted { siteTools.append(source) }
        } else if execution.serverID == CodexWebSearchTimeline.serverID {
          if execution.status == .succeeded {
            if webSearch == nil { webSearch = CodexWebSearchSummary() }
            webSearch?.add(execution.webSearchActivity ?? .legacy(execution),
              seenQueries: &seenQueries, seenLinks: &seenLinks)
          }
        } else if execution.serverID != CodexCommandTimeline.serverID
          && execution.serverID != CodexBrowserTimeline.serverID,
          !execution.serverName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          if let index = toolSources.firstIndex(where: { $0.id == execution.serverID }) {
            toolSources[index].calls.append(execution)
          } else {
            toolSources.append(MCPToolSource(id: execution.serverID,
              name: execution.serverName, calls: [execution]))
          }
        }
      }
    }
    var external = TaskExternalResourceCatalog.collect(self, library: library).sources
    if var webSearch {
      let viewedURLs = Set(webSearch.viewedLinks.compactMap { CodexWebSource.sourceKey($0.url) })
      external.removeAll { entry in
        let source = entry.source
        let urlKey = CodexWebSource.sourceKey(source.url)
        return source.activities == [.read] && urlKey.map(viewedURLs.contains) == true
          && !entry.hasMCPResource
      }
      let externalURLs = Set(external.compactMap { CodexWebSource.sourceKey($0.source.url) })
      webSearch.viewedLinks.removeAll { link in
        CodexWebSource.sourceKey(link.url).map(externalURLs.contains) ?? false
      }
      return files + external.map { .external($0.source) } + siteTools
        + toolSources.map(TaskSummarySource.tool)
        + (webSearch.queryCount == 0 && webSearch.viewedLinks.isEmpty
          ? [] : [.webSearch(webSearch)])
    }
    return files + external.map { .external($0.source) } + siteTools
      + toolSources.map(TaskSummarySource.tool)
  }
}
