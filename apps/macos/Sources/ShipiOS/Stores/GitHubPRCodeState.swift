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
  private(set) var groupExpanded = true
  private(set) var attributes: GitHubPRGeneratedAttributes?
  private(set) var attributesLoading = false
  private(set) var attributesError: String?
  private(set) var attributesStale = false
  var generatedPaths: Set<String> { attributes?.generated ?? [] }
  @ObservationIgnored private var attributesGeneration = UUID()
  @ObservationIgnored private var collapseOverrides: [String: Bool] = [:]
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
    guard files.contains(where: { $0.path == path }) else { return }
    if collapsed.contains(path) { collapsed.remove(path) } else { collapsed.insert(path) }
    collapseOverrides[path] = collapsed.contains(path)
  }
  func toggleAll() {
    groupExpanded.toggle()
    let close = !groupExpanded
    collapseOverrides = Dictionary(uniqueKeysWithValues: files.map { ($0.path, close) })
    applyCollapseDefaults()
  }
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
    collapseOverrides[file.path] = false
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
    resetAttributes()
    if changed { collapsed = []; collapseOverrides = [:]; groupExpanded = true; selectedPath = nil; position = nil }
    defer { if generation == token { loading = false } }
    do {
      let result = try await service.codeSnapshot(next)
      guard generation == token, !Task.isCancelled, valid() else { return }
      snapshot = result
      let paths = Set(result.files.map(\.path))
      collapseOverrides = collapseOverrides.filter { paths.contains($0.key) }
      applyCollapseDefaults()
      if selectedPath == nil || !paths.contains(selectedPath!) { selectedPath = result.files.first?.path }
      resolvePosition()
    } catch {
      guard generation == token, !Task.isCancelled, valid() else { return }
      self.error = error.localizedDescription
    }
  }
  func invalidate() {
    generation = UUID(); request = nil; snapshot = nil; loading = false; error = nil
    selectedPath = nil; position = nil; collapsed = []; collapseOverrides = [:]; groupExpanded = true; resetAttributes()
  }
  func cancel() { invalidate(); pendingPosition = nil; scope = nil }

  func loadAttributes(force: Bool = false, valid: @escaping @MainActor () -> Bool) async {
    guard let request, let code = snapshot, valid() else { return }
    if !force, attributes?.identity == code.identity, attributes?.paths == code.files.map(\.path) { return }
    attributesGeneration = UUID(); let token = attributesGeneration, codeToken = generation
    attributesLoading = true; attributesError = nil; attributesStale = false
    defer { if attributesGeneration == token { attributesLoading = false } }
    do {
      let result = code.files.isEmpty ? try GitHubPRGeneratedAttributes(code: code, sources: [])
        : try await service.generatedAttributes(request, code: code)
      guard attributesGeneration == token, generation == codeToken, snapshot == code,
        !Task.isCancelled, valid() else { return }
      attributes = result; applyCollapseDefaults()
    } catch {
      guard attributesGeneration == token, generation == codeToken, snapshot == code,
        !Task.isCancelled, valid() else { return }
      attributesError = error.localizedDescription
      attributesStale = error is GitHubPRCodeChanged
    }
  }
  private func applyCollapseDefaults() {
    collapsed = Set(files.filter { collapseOverrides[$0.path] ?? ($0.defaultCollapsed || generatedPaths.contains($0.path)) }.map(\.path))
  }
  private func resetAttributes() {
    attributesGeneration = UUID(); attributes = nil; attributesLoading = false
    attributesError = nil; attributesStale = false
  }
}
