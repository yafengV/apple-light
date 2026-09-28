import Foundation
import Observation

/// Ephemeral per-PR drafts are shared between windows, never persisted to user configuration.
@MainActor final class GitHubPREditRegistry {
  static let shared = GitHubPREditRegistry()
  private var states: [String: GitHubPREditState] = [:]
  func state(dataRoot: URL, root: URL, request: GitHubPullRequest) -> GitHubPREditState {
    let key = [dataRoot.standardizedFileURL.path,
      request.url.lowercased()].joined(separator: "\n")
    if let state = states[key] { return state }
    let state = GitHubPREditState(); states[key] = state; return state
  }
}

@MainActor @Observable final class GitHubPREditState {
  private(set) var title: GitHubPREditDraft?
  private(set) var body: GitHubPREditDraft?
  private(set) var saving: GitHubPREditField?
  private(set) var generating = false
  private(set) var snapshot: GitHubPRMergeSnapshot?
  private(set) var revision = UUID()
  private(set) var returnTitleFocus: UUID?
  private(set) var returnBodyFocus: UUID?
  private(set) var generationFocus: UUID?
  @ObservationIgnored private let service: GitHubPRService
  private let coordinator: GitHubPRActionCoordinator
  @ObservationIgnored private var owners: Set<UUID> = []
  @ObservationIgnored private var saveToken: UUID?
  @ObservationIgnored private var generationToken: UUID?
  @ObservationIgnored private(set) var operation: Task<Void, Never>?
  @ObservationIgnored private(set) var generationTask: Task<Void, Never>?

  init(service: GitHubPRService = .init(), coordinator: GitHubPRActionCoordinator? = nil) {
    self.service = service; self.coordinator = coordinator ?? .shared
  }
  func attach(_ owner: UUID) { owners.insert(owner) }
  func detach(_ owner: UUID) {
    owners.remove(owner)
    if owners.isEmpty { cancelWork() }
  }
  func busy(_ request: GitHubPullRequest) -> Bool { coordinator.isBusy(request.url) }
  func begin(_ field: GitHubPREditField, snapshot: GitHubPRMergeSnapshot, request: GitHubPullRequest,
    writable: Bool) {
    guard writable, !busy(request), field != .body || (!generating && GitHubPREditText.canEditBody(snapshot)) else { return }
    let draft = GitHubPREditDraft(text: GitHubPREditText.value(field, in: snapshot))
    if field == .title { if title == nil { title = draft } }
    else { if body == nil { body = draft } }
  }
  func change(_ field: GitHubPREditField, text: String) {
    guard saving == nil, field != .body || !generating else { return }
    if field == .title {
      title?.text = GitHubPREditText.title(text); title?.error = nil
    } else { body?.text = text; body?.error = nil; body?.startedFromEmptyView = false }
  }
  func cancel(_ field: GitHubPREditField, request: GitHubPullRequest) {
    guard !busy(request) else { return }
    if field == .body, generating { stopGeneration(); return }
    if field == .title { title = nil; returnTitleFocus = UUID() }
    else { body = nil; returnBodyFocus = UUID() }
  }
  func canSave(_ field: GitHubPREditField, snapshot: GitHubPRMergeSnapshot?,
    request: GitHubPullRequest, writable: Bool) -> Bool {
    guard writable, !busy(request), let snapshot else { return false }
    if field == .body { return body != nil && !generating && GitHubPREditText.canEditBody(snapshot) }
    guard let title else { return false }
    let text = GitHubPREditText.trimmed(title.text)
    return !text.isEmpty && text != GitHubPREditText.trimmed(snapshot.details.title)
  }

  @discardableResult func save(_ field: GitHubPREditField, snapshot: GitHubPRMergeSnapshot?,
    request: GitHubPullRequest, at root: URL, valid: @escaping @MainActor () -> Bool,
    writable: @escaping @MainActor () -> Bool,
    updated: @escaping @MainActor (GitHubPullRequest) -> Void) -> Bool {
    guard valid(), canSave(field, snapshot: snapshot, request: request, writable: writable()),
      let draft = field == .title ? title : body else { return false }
    let token = UUID()
    guard coordinator.begin(request.url, token: token) else { return false }
    saveToken = token; saving = field
    if field == .title { title?.error = nil } else { body?.error = nil }
    operation = Task {
      defer {
        coordinator.end(request.url, token: token)
        if saveToken == token { saveToken = nil; saving = nil; operation = nil }
      }
      do {
        let result = try await service.edit(field, text: draft.text, request: request, at: root) {
          guard valid(), writable(), self.saveToken == token else { throw CancellationError() }
        }
        guard !Task.isCancelled, valid(), saveToken == token else { return }
        accept(result, request: request, updated: updated)
        if field == .title, title?.focus == draft.focus { title = nil; returnTitleFocus = UUID() }
        if field == .body, body?.focus == draft.focus { body = nil; returnBodyFocus = UUID() }
      } catch {
        guard !Task.isCancelled, valid(), saveToken == token else { return }
        if let snapshot = (error as? GitHubPREditFailure)?.snapshot {
          accept(snapshot, request: request, updated: updated)
        }
        if field == .title { title?.error = error.localizedDescription }
        else { body?.error = error.localizedDescription }
      }
    }
    return true
  }

  @discardableResult func generate(snapshot: GitHubPRMergeSnapshot, request: GitHubPullRequest,
    instructions: String, at root: URL, valid: @escaping @MainActor () -> Bool,
    writable: @escaping @MainActor () -> Bool, generate: @escaping GitTextGeneration,
    updated: @escaping @MainActor (GitHubPullRequest) -> Void) -> Bool {
    guard valid(), writable(), !busy(request), !generating, GitHubPREditText.canEditBody(snapshot) else { return false }
    let original = body?.text ?? snapshot.details.body ?? ""
    let fromEmpty = body == nil && GitHubPREditText.trimmed(original).isEmpty
    if body == nil { body = .init(text: original, startedFromEmptyView: fromEmpty) }
    body?.error = nil
    let token = UUID(), draftID = body?.focus
    generationToken = token; generating = true; generationFocus = UUID()
    generationTask = Task {
      defer {
        if generationToken == token { generationToken = nil; generating = false; generationTask = nil }
      }
      do {
        let (text, latest) = try await service.generateDescription(request: request, expected: snapshot,
          body: original, instructions: instructions, at: root, generate: generate) {
            guard valid(), writable(), self.generationToken == token else { throw CancellationError() }
          }
        guard !Task.isCancelled, valid(), writable(), generationToken == token,
          body?.focus == draftID, body?.text == original else { return }
        body?.text = text; body?.error = nil
        accept(latest, request: request, updated: updated)
      } catch {
        guard !Task.isCancelled, valid(), generationToken == token, body?.focus == draftID else { return }
        body?.error = error.localizedDescription
      }
    }
    return true
  }
  func reportGenerationError(_ message: String, snapshot: GitHubPRMergeSnapshot,
    request: GitHubPullRequest, writable: Bool) {
    begin(.body, snapshot: snapshot, request: request, writable: writable)
    if !generating, !busy(request) { body?.error = message }
  }
  func stopGeneration() {
    generationToken = nil; generating = false
    generationTask?.cancel(); generationTask = nil
  }
  func cancelWork() {
    stopGeneration(); saveToken = nil; saving = nil
    operation?.cancel(); operation = nil
  }
  private func accept(_ result: GitHubPRMergeSnapshot, request: GitHubPullRequest,
    updated: (GitHubPullRequest) -> Void) {
    snapshot = result; revision = UUID(); updated(result.details.recorded(updating: request))
  }
}
