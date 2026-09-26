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
  private(set) var resultsRequest: WorkspaceFileSearchRequest?
  private(set) var searching = false
  private(set) var error: String?
  private(set) var request: WorkspaceFileSearchRequest?
  private var version = UUID()
  @ObservationIgnored private var session: (any FileSearchSession)?
  @ObservationIgnored private let sessionFactory: @MainActor (WorkspaceFileSearchRequest) throws -> any FileSearchSession

  init(sessionFactory: @escaping @MainActor (WorkspaceFileSearchRequest) throws -> any FileSearchSession = { request in
    guard let root = request.root else { throw AgentFailure(message: "请先选择项目。") }
    return try WorkspaceFileSearchSession(root: root, executable: request.executable)
  }) {
    self.sessionFactory = sessionFactory
  }

  func results(for request: WorkspaceFileSearchRequest) -> [WorkspaceFileSearchResult] {
    guard resultsRequest == request,
      !request.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
    return results
  }

  func search(_ request: WorkspaceFileSearchRequest,
    loader: Loader? = nil) async {
    let token = UUID()
    version = token
    if self.request?.root != request.root || self.request?.executable != request.executable || self.request?.retry != request.retry {
      session?.close(); session = nil
      results = []; resultsRequest = nil
    }
    self.request = request
    error = nil; searching = false
    guard request.root != nil, !request.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      results = []; resultsRequest = nil; session?.cancelQuery(); return
    }
    searching = true
    defer { if version == token { searching = false } }
    do {
      try Task.checkCancellation()
      if let loader {
        let candidates = try await loader(request)
        guard !Task.isCancelled, version == token else { return }
        results = WorkspaceFileSearchResult.ranked(candidates, query: request.query)
        resultsRequest = request
      } else {
        try await Task.sleep(for: .milliseconds(75))
        guard !Task.isCancelled, version == token else { return }
        if session == nil { session = try sessionFactory(request) }
        guard let session else { return }
        let updates = try session.query(request.query)
        for try await update in updates {
          guard !Task.isCancelled, version == token else { return }
          results = WorkspaceFileSearchResult.ranked(update.files, query: request.query)
          resultsRequest = request
          searching = !update.complete
        }
      }
    } catch {
      guard !Task.isCancelled, version == token else { return }
      self.error = error.localizedDescription
      session?.close(); session = nil
    }
  }

  func close() {
    version = UUID()
    session?.close(); session = nil
    request = nil; results = []; resultsRequest = nil; searching = false; error = nil
  }
}
