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
  private(set) var scrollOffset: Double = 0
  private(set) var scrollGeneration = UUID()
  private(set) var position: GitHubPRCommentPosition?
  private(set) var navigation = UUID()
  private(set) var navigationPending = false
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
  var presentation: GitHubPRCodePresentation {
    .init(query: query, showsFiles: showsFiles, selectedPath: selectedPath, scrollOffset: scrollOffset)
  }
  func restorePresentation(_ value: GitHubPRCodePresentation) {
    guard snapshot != nil, !navigationPending, pendingPosition == nil else { return }
    query = value.query
    showsFiles = value.showsFiles
    selectedPath = files.contains(where: { $0.path == value.selectedPath })
      ? value.selectedPath : files.first?.path
    scrollOffset = value.scrollOffset.isFinite ? max(0, value.scrollOffset) : 0
    scrollGeneration = UUID()
  }
  var filteredFiles: [GitHubPRCodeFile] {
    let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return search.isEmpty ? files : files.filter { $0.path.localizedCaseInsensitiveContains(search) }
  }
  var activeFilteredPath: String? {
    let visible = filteredFiles
    return visible.first(where: { $0.path == selectedPath })?.path ?? visible.first?.path
  }
  var allCollapsed: Bool { !files.isEmpty && files.allSatisfy { collapsed.contains($0.path) } }
  func toggle(_ path: String, all: Bool = false) {
    guard files.contains(where: { $0.path == path }) else { return }
    if all { setAllExpanded(collapsed.contains(path)); return }
    if collapsed.contains(path) { collapsed.remove(path) } else { collapsed.insert(path) }
    collapseOverrides[path] = collapsed.contains(path)
  }
  func toggleAll() {
    setAllExpanded(!groupExpanded)
  }
  private func setAllExpanded(_ open: Bool) {
    groupExpanded = open
    let close = !open
    collapseOverrides = Dictionary(uniqueKeysWithValues: files.map { ($0.path, close) })
    applyCollapseDefaults()
  }
  func select(_ path: String) {
    guard files.contains(where: { $0.path == path }) else { return }
    selectedPath = path; position = nil; navigation = UUID(); navigationPending = true
  }
  func endNavigation() { navigationPending = false }
  func rememberScrollOffset(_ offset: Double) {
    guard offset.isFinite else { return }
    scrollOffset = max(0, offset)
  }
  func open(_ target: GitHubPRCommentPosition) {
    guard target.isValid else { return }
    page = .code; query = ""; position = nil; pendingPosition = target
    resolvePosition()
  }
  func richPreviewText(_ file: GitHubPRCodeFile, identity: GitHubPRCodeIdentity) async throws -> String {
    guard let request, let snapshot, snapshot.identity == identity, snapshot.files.contains(file) else {
      throw GitHubPRCodeChanged(message: "PR 代码版本已变化，请刷新差异后重试预览。")
    }
    let text = try await service.richPreviewText(request, code: snapshot, file: file)
    guard self.request == request, self.snapshot?.identity == identity,
      self.snapshot?.files.contains(file) == true else {
      throw GitHubPRCodeChanged(message: "PR 代码版本已变化，请刷新差异后重试预览。")
    }
    return text
  }
  func markdownContext(_ file: GitHubPRCodeFile,
    identity: GitHubPRCodeIdentity) -> GitHubPRMarkdownContext? {
    guard let request, snapshot?.identity == identity,
      snapshot?.files.contains(file) == true else { return nil }
    return GitHubPRMarkdownContext(pullRequestURL: request.pullRequest.validatedURL,
      head: identity.head, filePath: file.path)
  }
  func markdownImage(_ file: GitHubPRCodeFile, identity: GitHubPRCodeIdentity,
    path: String) async throws -> Data {
    guard let request, let snapshot, snapshot.identity == identity,
      snapshot.files.contains(file) else {
      throw GitHubPRCodeChanged(message: "PR 代码版本已变化，请刷新差异后重试预览。")
    }
    let bytes = try await service.markdownImage(request, code: snapshot, file: file, path: path)
    guard self.request == request, self.snapshot?.identity == identity,
      self.snapshot?.files.contains(file) == true else {
      throw GitHubPRCodeChanged(message: "PR 代码版本已变化，请刷新差异后重试预览。")
    }
    return bytes
  }
  func binaryPreview(_ file: GitHubPRCodeFile, identity: GitHubPRCodeIdentity,
    richPreviewEnabled: Bool) async throws -> GitHubPRRichPreview.Binary {
    guard let request, let snapshot, snapshot.identity == identity, snapshot.files.contains(file) else {
      throw GitHubPRCodeChanged(message: "PR 代码版本已变化，请刷新差异后重试预览。")
    }
    let result = try await service.binaryPreview(request, code: snapshot, file: file,
      richPreviewEnabled: richPreviewEnabled)
    guard self.request == request, self.snapshot?.identity == identity,
      self.snapshot?.files.contains(file) == true else {
      throw GitHubPRCodeChanged(message: "PR 代码版本已变化，请刷新差异后重试预览。")
    }
    return result
  }
  private func resolvePosition() {
    guard let target = pendingPosition, let file = files.first(where: { $0.matches(target) }) else { return }
    selectedPath = file.path; position = target; collapsed.remove(file.path)
    collapseOverrides[file.path] = false
    pendingPosition = nil; navigation = UUID(); navigationPending = true
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
    if changed {
      collapsed = []; collapseOverrides = [:]; groupExpanded = true; selectedPath = nil; position = nil
      scrollOffset = 0; scrollGeneration = UUID(); navigationPending = false
    }
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
    selectedPath = nil; position = nil; scrollOffset = 0; scrollGeneration = UUID(); navigationPending = false
    collapsed = []; collapseOverrides = [:]; groupExpanded = true; resetAttributes()
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
