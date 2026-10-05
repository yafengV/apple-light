import AppKit
import Observation
import UniformTypeIdentifiers

@MainActor @Observable final class SubagentDetailState {
  private(set) var selected: CodexSubagent?
  private(set) var transcript = SubagentTranscript()
  private(set) var loading = false
  private(set) var sending = false
  private(set) var error: String?
  var draft = ""
  var images: [ImageAttachment] = []
  var files: [FileAttachment] = []
  private(set) var importing = false
  private(set) var attachmentError: String?
  var hasInput: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty || !files.isEmpty }
  private var generation = UUID()
  private var importGeneration = UUID()
  private var history: [JSONValue] = []
  private var live: SubagentLiveState?

  func updateLive(_ state: SubagentLiveState?) {
    live = state; rebuild()
  }

  private func rebuild() {
    transcript = .init(events: live?.merged(with: history) ?? history)
  }

  func select(_ agent: CodexSubagent?) {
    generation = UUID(); selected = agent; transcript = .init(); history = []; live = nil
    clearDraft(); loading = false; sending = false; importing = false; error = nil
  }

  func update(_ agent: CodexSubagent) {
    if agent.id == selected?.id { selected = agent }
  }

  func load(using read: (CodexSubagent) async throws -> [JSONValue]) async {
    guard let agent = selected else { return }
    let token = generation
    loading = transcript.entries.isEmpty
    defer { if token == generation { loading = false } }
    do {
      let events = try await read(agent)
      guard token == generation, !Task.isCancelled else { return }
      history = events; rebuild(); error = nil
    } catch {
      guard token == generation, !Task.isCancelled, !(error is CancellationError) else { return }
      self.error = error.localizedDescription
    }
  }

  func send(working: Bool, using submit: (CodexSubagent, String, String?) async throws -> String) async -> Bool {
    guard images.isEmpty, files.isEmpty else { return false }
    return await sendMessage(working: working) { agent, message, turn in try await submit(agent, message.content, turn) }
  }

  func clearDraft() {
    importGeneration = UUID(); importing = false
    draft = ""; images = []; files = []; attachmentError = nil
  }

  func sendMessage(working: Bool, using submit: (CodexSubagent, ChatMessage, String?) async throws -> String) async -> Bool {
    guard let agent = selected, agent.acceptsInput, !sending,
      !importing, hasInput,
      !working || transcript.activeTurnID != nil else { return false }
    let token = generation, message = ChatMessage(role: "user", content: draft, images: images, files: files)
    sending = true
    defer { if token == generation { sending = false } }
    do {
      _ = try await submit(agent, message, working ? transcript.activeTurnID : nil)
      guard token == generation, !Task.isCancelled else { return false }
      if draft == message.content { draft = "" }
      let imageIDs = Set(message.images.map(\.id)), fileIDs = Set(message.files.map(\.id))
      images.removeAll { imageIDs.contains($0.id) }; files.removeAll { fileIDs.contains($0.id) }
      error = nil; sending = false
      return true
    } catch {
      guard token == generation, !Task.isCancelled else { return false }
      self.error = error.localizedDescription; sending = false
      return false
    }
  }

  func importAttachments(_ sources: [SubagentAttachmentSource], root: URL) async -> Bool {
    await importAttachments(root: root) { sources }
  }

  func importProviders(_ providers: [NSItemProvider], root: URL, timeout: Duration = .seconds(20)) async -> Bool {
    await importAttachments(root: root) { try await SubagentAttachmentImport.sources(providers, timeout: timeout) }
  }

  private func importAttachments(root: URL, read: () async throws -> [SubagentAttachmentSource]) async -> Bool {
    guard selected?.acceptsInput == true, !sending, !importing else { return false }
    let token = generation, importToken = UUID(), imageCount = images.count, fileCount = files.count
    importGeneration = importToken
    importing = true; attachmentError = nil
    defer { if token == generation, importToken == importGeneration { importing = false } }
    do {
      let sources = try await read()
      guard token == generation, importToken == importGeneration, !Task.isCancelled else { return false }
      let imported = try await Task.detached(priority: .userInitiated) {
        try SubagentAttachmentImport.load(sources, root: root, imageCount: imageCount, fileCount: fileCount)
      }.value
      guard token == generation, importToken == importGeneration, !Task.isCancelled else { imported.discard(root: root); return false }
      images.append(contentsOf: imported.images); files.append(contentsOf: imported.files)
      return true
    } catch {
      guard token == generation, importToken == importGeneration, !Task.isCancelled, !(error is CancellationError) else { return false }
      attachmentError = error.localizedDescription; return false
    }
  }

  func chooseAttachments(root: URL, window: NSWindow, imagesOnly: Bool = false) {
    guard selected?.acceptsInput == true, !sending, !importing else { return }
    let token = generation, importToken = importGeneration, panel = NSOpenPanel()
    panel.title = imagesOnly ? "添加图片" : "添加附件"
    panel.canChooseDirectories = !imagesOnly; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
    if imagesOnly { panel.allowedContentTypes = [.image] }
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK else { return }
      Task { @MainActor in
        guard let self, self.generation == token, self.importGeneration == importToken else { return }
        _ = await self.importAttachments(panel.urls.map(SubagentAttachmentSource.file), root: root)
      }
    }
  }
}
