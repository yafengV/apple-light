import Foundation
import Markdown

/// A file linked by an assistant reply that still exists inside that run's workspace.
struct TaskSummaryLinkedFile: Identifiable, Equatable {
  let runID: String
  let root: URL
  let path: String
  let url: URL

  var id: String { url.path }
  var title: String { url.lastPathComponent }
  var searchableText: String { path }

  /// Recheck containment at click time before revealing a workspace preview.
  func previewPath(in workspaceRoot: URL) -> String? {
    guard root.resolvingSymlinksInPath().standardizedFileURL
      == workspaceRoot.resolvingSymlinksInPath().standardizedFileURL,
      case .file(let path, _) = try? MessageLink.target(url, root: workspaceRoot) else { return nil }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
      !isDirectory.boolValue else { return nil }
    return path
  }
}

enum TaskSummaryLinkedFiles {
  static func collect(_ runs: [AgentRun], rootForRun: (AgentRun) -> URL?) -> [TaskSummaryLinkedFile] {
    var seen = Set<String>()
    var files: [TaskSummaryLinkedFile] = []
    for run in runs where run.kind == "chat" {
      guard let root = rootForRun(run) else { continue }
      for item in run.displayedResponseItems {
        guard case .message(_, let source) = item else { continue }
        for destination in destinations(in: Document(parsing: source)) {
          guard let link = MessageLink.url(destination),
            case .file(let path, _) = try? MessageLink.target(link, root: root) else { continue }
          let url = root.resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
          var isDirectory: ObjCBool = false
          guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            !isDirectory.boolValue, seen.insert(url.path).inserted else { continue }
          files.append(.init(runID: run.id, root: root, path: path, url: url))
        }
      }
    }
    return files
  }

  private static func destinations(in markup: any Markup) -> [String] {
    var found: [String] = []
    if let link = markup as? Markdown.Link, let destination = link.destination {
      found.append(destination)
    } else if let image = markup as? Markdown.Image, let source = image.source {
      found.append(source)
    }
    for child in markup.children { found.append(contentsOf: destinations(in: child)) }
    return found
  }
}
