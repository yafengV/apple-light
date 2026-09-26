import Foundation

enum TaskSummarySource: Identifiable, Equatable {
  case file(FileAttachment)
  case image(ImageAttachment)
  case external(CodexWebSource)
  case tool(id: UUID, name: String)
  case webSearch

  var id: String {
    switch self {
    case .file(let file): "file:\(file.id.uuidString)"
    case .image(let image): "image:\(image.id.uuidString)"
    case .external(let source): "external:\(source.url)"
    case .tool(let id, _): "tool:\(id.uuidString)"
    case .webSearch: "web-search"
    }
  }
}

extension Collection where Element == AgentRun {
  func summarySources(in library: WorkspaceLibrary) -> [TaskSummarySource] {
    var files: [TaskSummarySource] = []
    var external: [TaskSummarySource] = []
    var tools: [TaskSummarySource] = []
    var seen = Set<String>()
    var hasWebSearch = false
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
        if execution.serverID == CodexWebSearchTimeline.serverID {
          hasWebSearch = true
        } else if execution.serverID != CodexCommandTimeline.serverID,
          !execution.serverName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          let source = TaskSummarySource.tool(id: execution.serverID, name: execution.serverName)
          if seen.insert(source.id).inserted { tools.append(source) }
        }
      }
    }
    return files + external + tools + (hasWebSearch ? [.webSearch] : [])
  }
}
