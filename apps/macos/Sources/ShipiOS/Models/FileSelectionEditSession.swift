import AppKit
import Observation

@MainActor @Observable
final class FileSelectionEditSession {
  var isPresented = false
  var instruction = "" {
    didSet { if instruction != oldValue { proposal = nil; error = nil } }
  }
  private(set) var candidate: NSRange?
  private(set) var generating = false
  private(set) var proposal: FileSelectionEditProposal?
  private(set) var error: String?
  private(set) var request: FileSelectionEditRequest?
  @ObservationIgnored weak var editor: FilePreviewTextView?
  @ObservationIgnored private var generation: Task<Void, Never>?
  @ObservationIgnored private var token = UUID()

  func bind(editor: FilePreviewTextView?) { self.editor = editor }

  func selectionChanged(in editor: FilePreviewTextView) {
    guard self.editor === editor else { return }
    let range = editor.selectedRange()
    if range.length > 0, range.length <= FileSelectionEditRequest.maximumSelectionLength,
      let swiftRange = Range(range, in: editor.string),
      !editor.string[swiftRange].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      candidate = range
    } else {
      candidate = nil
    }
  }

  func open(path: String, source: String) {
    guard let editor, editor.isEditable, let candidate,
      editor.string.utf8.elementsEqual(source.utf8),
      editor.selectedRange() == candidate else { return }
    cancelGeneration()
    request = FileSelectionEditRequest(path: path, source: source,
      range: candidate, instruction: "")
    instruction = ""
    proposal = nil
    error = nil
    isPresented = true
  }

  func generate(using operation: @escaping @MainActor (FileSelectionEditRequest) async throws -> FileSelectionEditProposal) {
    guard var request else { return }
    cancelGeneration()
    request = FileSelectionEditRequest(path: request.path, source: request.source,
      range: request.range, instruction: instruction)
    self.request = request
    proposal = nil
    error = nil
    generating = true
    let current = token
    generation = Task { [weak self] in
      do {
        let value = try await operation(request)
        guard let self, self.token == current else { return }
        self.proposal = value
        self.generating = false
      } catch {
        guard let self, self.token == current else { return }
        self.error = error.localizedDescription
        self.generating = false
      }
    }
  }

  func canGenerate(path: String?, source: String) -> Bool {
    guard isPresented, let editor, editor.isEditable, let request,
      path == request.path, editor.selectedRange() == request.range,
      editor.string.utf8.elementsEqual(request.source.utf8),
      source.utf8.elementsEqual(request.source.utf8) else { return false }
    return true
  }

  func canApply(path: String?, source: String) -> Bool {
    canGenerate(path: path, source: source) && proposal != nil
  }

  @discardableResult func accept(path: String?, source: String) -> Bool {
    guard canApply(path: path, source: source), let editor, let request, let proposal else {
      error = "文件或选区已变化，请重新选择后生成修改。"
      return false
    }
    editor.insertText(proposal.replacement, replacementRange: request.range)
    close()
    return true
  }

  func close() {
    cancelGeneration()
    isPresented = false
    instruction = ""
    request = nil
    proposal = nil
    error = nil
  }

  func cancel() {
    cancelGeneration()
    proposal = nil
    error = nil
  }

  func revise() {
    cancelGeneration()
    proposal = nil
    error = nil
  }

  func reset() {
    close()
    candidate = nil
  }

  private func cancelGeneration() {
    token = UUID()
    generation?.cancel()
    generation = nil
    generating = false
  }
}
