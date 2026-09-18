import Foundation
import Observation

struct WorkspaceFileSearchResult: Decodable, Equatable, Sendable, Identifiable {
  let path: String
  let isDirectory: Bool
  let score: Int
  var id: String { path }
  var title: String { (path as NSString).lastPathComponent }
  var directory: String { (path as NSString).deletingLastPathComponent }
  func directoryURL(root: URL) throws -> URL {
    let url = try LocalWorkspaceService.resolvedFile(path, root: root)
    guard isDirectory, try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
      throw AgentFailure(message: "目录已不存在，请重新搜索。")
    }
    return url
  }

  // The desktop excludes these components after the backend candidate limit.
  static let excluded: Set<String> = [".git", ".hg", ".next", ".pnpm-store", ".svn", ".turbo", ".yarn",
    "build", "coverage", "dist", "node_modules"]
  static func ranked(_ candidates: [Self], query: String) -> [Self] {
    let pattern = DesktopFuzzyQuery(query)
    return candidates.enumerated().filter { _, result in
      !result.path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).contains { excluded.contains(String($0)) }
    }.map { index, result in (index: index, result: result, score: pattern.match(result.title)?.score ?? 0) }
      .sorted {
        if $0.score != $1.score { return $0.score > $1.score }
        if !$0.result.title.utf16.elementsEqual($1.result.title.utf16) {
          return $0.result.title.utf16.lexicographicallyPrecedes($1.result.title.utf16)
        }
        return $0.index < $1.index
      }.map(\.result)
  }
}

struct WorkspaceFileSearchRequest: Equatable, Sendable {
  let root: URL?
  let query: String
  let executable: URL
  var retry = 0
}

@MainActor @Observable final class WorkspaceFileSearchCatalog {
  typealias Loader = @Sendable (WorkspaceFileSearchRequest) async throws -> [WorkspaceFileSearchResult]
  private(set) var results: [WorkspaceFileSearchResult] = []
  private(set) var searching = false
  private(set) var error: String?
  private(set) var request: WorkspaceFileSearchRequest?
  private var version = UUID()

  func search(_ request: WorkspaceFileSearchRequest,
    loader: Loader = { try await WorkspaceFileSearchCatalog.load($0) }) async {
    let token = UUID()
    version = token
    self.request = request
    results = []; error = nil; searching = false
    guard request.root != nil, !request.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    searching = true
    defer { if version == token { searching = false } }
    do {
      try Task.checkCancellation()
      let candidates = try await loader(request)
      guard !Task.isCancelled, version == token else { return }
      results = WorkspaceFileSearchResult.ranked(candidates, query: request.query)
    } catch {
      guard !Task.isCancelled, version == token else { return }
      self.error = error.localizedDescription
    }
  }

  nonisolated private static func load(_ request: WorkspaceFileSearchRequest) async throws -> [WorkspaceFileSearchResult] {
    guard let root = request.root else { return [] }
    // Debounce typing before starting an isolated helper process.
    try await Task.sleep(for: .milliseconds(75))
    let output = try await LocalWorkspaceService.command(request.executable.path,
      ["--project", root.path, "search-files", "--query", request.query.trimmingCharacters(in: .whitespacesAndNewlines)],
      at: root, cancelWithTask: true)
    guard output.status == 0 else { throw AgentFailure(message: output.text) }
    return try JSONDecoder().decode([WorkspaceFileSearchResult].self, from: Data(output.text.utf8))
  }
}
