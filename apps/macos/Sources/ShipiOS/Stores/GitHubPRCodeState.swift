import Foundation
import Observation

@MainActor @Observable final class GitHubPRCodeState {
  enum Page: String, CaseIterable { case summary, code }
  var page = Page.summary
  var query = ""
  var showsFiles = false
  var split = false
  var wrap = false
  private(set) var snapshot: GitHubPRCodeSnapshot?
  private(set) var loading = false
  private(set) var error: String?
  private(set) var selectedPath: String?
  private(set) var position: GitHubPRCommentPosition?
  private(set) var navigation = UUID()
  private(set) var collapsed = Set<String>()
  @ObservationIgnored private var request: GitHubPRCodeRequest?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var pendingPosition: GitHubPRCommentPosition?
  @ObservationIgnored private var scope: String?
  @ObservationIgnored private let service: GitHubPRService
  init(service: GitHubPRService = .init()) { self.service = service }
  var files: [GitHubPRCodeFile] { snapshot?.files ?? [] }
  var filteredFiles: [GitHubPRCodeFile] {
    let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return search.isEmpty ? files : files.filter { $0.path.localizedCaseInsensitiveContains(search) }
  }
  var allCollapsed: Bool { !files.isEmpty && files.allSatisfy { collapsed.contains($0.path) } }
  func toggle(_ path: String) {
    if collapsed.contains(path) { collapsed.remove(path) } else { collapsed.insert(path) }
  }
  func toggleAll() { collapsed = allCollapsed ? [] : Set(files.map(\.path)) }
  func select(_ path: String) {
    guard files.contains(where: { $0.path == path }) else { return }
    selectedPath = path; position = nil; navigation = UUID()
  }
  func open(_ target: GitHubPRCommentPosition) {
    guard target.isValid else { return }
    page = .code; query = ""; position = nil; pendingPosition = target
    resolvePosition()
  }
  private func resolvePosition() {
    guard let target = pendingPosition, let file = files.first(where: { $0.matches(target) }) else { return }
    selectedPath = file.path; position = target; collapsed.remove(file.path)
    pendingPosition = nil; navigation = UUID()
  }
  func rowTarget(in file: GitHubPRCodeFile) -> String? {
    guard let position, file.matches(position) else { return nil }
    return file.diff.lines.first { (position.side == .left ? $0.oldLine : $0.newLine) == position.line }
      .map { file.lineID($0) }
  }
  func load(_ next: GitHubPRCodeRequest?, valid: @escaping @MainActor () -> Bool) async {
    guard let next, valid() else { invalidate(); return }
    if request == next, snapshot != nil { return }
    await refresh(next, valid: valid)
  }
  func refresh(_ next: GitHubPRCodeRequest, valid: @escaping @MainActor () -> Bool) async {
    let nextScope = next.taskID + "\u{1f}" + next.root.path + "\u{1f}" + next.pullRequest.url
    if let scope, scope != nextScope { pendingPosition = nil; query = ""; showsFiles = false }
    scope = nextScope
    let changed = request != next
    generation = UUID(); let token = generation
    request = next; loading = true; error = nil; snapshot = nil
    if changed { collapsed = []; selectedPath = nil; position = nil }
    defer { if generation == token { loading = false } }
    do {
      let result = try await service.codeSnapshot(next)
      guard generation == token, !Task.isCancelled, valid() else { return }
      snapshot = result
      let paths = Set(result.files.map(\.path))
      collapsed = changed ? Set(result.files.filter(\.defaultCollapsed).map(\.path)) : collapsed.intersection(paths)
      if selectedPath == nil || !paths.contains(selectedPath!) { selectedPath = result.files.first?.path }
      resolvePosition()
    } catch {
      guard generation == token, !Task.isCancelled, valid() else { return }
      self.error = error.localizedDescription
    }
  }
  func invalidate() {
    generation = UUID(); request = nil; snapshot = nil; loading = false; error = nil
    selectedPath = nil; position = nil; collapsed = []
  }
  func cancel() { invalidate(); pendingPosition = nil; scope = nil }
}
