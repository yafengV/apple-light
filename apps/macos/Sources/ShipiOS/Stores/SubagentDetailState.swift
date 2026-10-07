import AppKit
import Observation
import UniformTypeIdentifiers

@MainActor @Observable final class SubagentDetailState {
  private(set) var selected: CodexSubagent?
  private(set) var transcript = SubagentTranscript()
  private(set) var loading = false
  private(set) var sending = false
  private(set) var error: String?
  @ObservationIgnored private weak var draftStore: WorkspaceStore?
  private var draftTaskID: String?
  private var localMessage = ChatMessage(role: "user", content: "")
  private var localContentRevision = UUID()
  private var localDraftEpoch = UUID()
  private var draftScope: SubagentDraftScope? {
    guard let draftTaskID, let selected else { return nil }
    return .init(taskID: draftTaskID, rootThreadID: selected.rootThreadID, childThreadID: selected.threadID)
  }
  private var savedDraft: SubagentDraft? { draftScope.flatMap { draftStore?.subagentDraft($0) } }
  private var message: ChatMessage {
    draftStore == nil ? localMessage : savedDraft?.message ?? .init(role: "user", content: "")
  }
  var draft: String {
    get { message.content }
    set { setMessage(.init(role: "user", content: newValue, images: message.images, files: message.files)) }
  }
  var images: [ImageAttachment] {
    get { message.images }
    set { setMessage(.init(role: "user", content: message.content, images: newValue, files: message.files)) }
  }
  var files: [FileAttachment] {
    get { message.files }
    set { setMessage(.init(role: "user", content: message.content, images: message.images, files: newValue)) }
  }
  var draftSaveError: String? { draftScope.flatMap { draftStore?.subagentDraftSaveErrors[$0] } }
  private var contentRevision: UUID? { draftStore == nil ? localContentRevision : savedDraft?.contentRevision }
  private var draftEpoch: UUID {
    if let draftStore, let draftScope { return draftStore.subagentDraftEpoch(draftScope) }
    return localDraftEpoch
  }
  private(set) var importing = false
  private(set) var attachmentError: String?
  var hasInput: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty || !files.isEmpty }
  private var generation = UUID()
  private var importGeneration = UUID()
  private var history: [JSONValue] = []
  private var live: SubagentLiveState?

  func bindDrafts(to store: WorkspaceStore, taskID: String) {
    draftStore = store; draftTaskID = taskID
    if selected != nil, savedDraft == nil,
      !localMessage.content.isEmpty || !localMessage.images.isEmpty || !localMessage.files.isEmpty {
      setMessage(localMessage)
    }
    localMessage = .init(role: "user", content: "")
  }

  private func replaceMessage(_ message: ChatMessage) throws {
    if let draftStore, let draftScope { try draftStore.updateSubagentDraft(draftScope, message: message) }
    else {
      if localMessage.content != message.content { localContentRevision = UUID() }
      localMessage = message
    }
  }

  private func setMessage(_ message: ChatMessage) {
    do { try replaceMessage(message) } catch { self.error = error.localizedDescription }
  }

  @discardableResult func retryDraftSave() -> Bool {
    do {
      if let draftStore, let draftScope { try draftStore.persistSubagentDraft(draftScope) }
      return true
    } catch {
      if draftSaveError == nil { self.error = error.localizedDescription }
      return false
    }
  }

  func updateLive(_ state: SubagentLiveState?) {
    live = state; rebuild()
  }

  private func rebuild() {
    transcript = .init(events: live?.merged(with: history) ?? history)
  }

  func select(_ agent: CodexSubagent?) {
    generation = UUID(); selected = agent; transcript = .init(); history = []; live = nil
    // Panel selection is local; a bound conversation's draft survives Back/remount.
    cancelPendingAttachmentImport(); localMessage = .init(role: "user", content: "")
    localContentRevision = UUID(); localDraftEpoch = UUID()
    attachmentError = nil; loading = false; sending = false; error = nil
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
    cancelPendingAttachmentImport(); localDraftEpoch = UUID()
    if let draftStore, let draftScope { draftStore.invalidateSubagentDraftImports(draftScope) }
    setMessage(.init(role: "user", content: "")); attachmentError = nil
  }

  func cancelPendingAttachmentImport() {
    importGeneration = UUID(); importing = false
  }

  func sendMessage(working: Bool, using submit: (CodexSubagent, ChatMessage, String?) async throws -> String) async -> Bool {
    guard let agent = selected, agent.acceptsInput, !sending,
      !importing, hasInput,
      !working || transcript.activeTurnID != nil else { return false }
    let token = generation, message = message, submittedContentRevision = contentRevision
    let ownerStore = draftStore, ownerScope = draftScope
    sending = true
    defer { if token == generation { sending = false } }
    do {
      if let draftStore, let draftScope { try draftStore.persistSubagentDraft(draftScope) }
    } catch {
      if draftSaveError == nil { self.error = error.localizedDescription }
      return false
    }
    do {
      _ = try await submit(agent, message, working ? transcript.activeTurnID : nil)
      let imageIDs = Set(message.images.map(\.id)), fileIDs = Set(message.files.map(\.id))
      do {
        if let ownerStore, let ownerScope {
          // A confirmed send belongs to its original conversation even after Back
          // or selecting a different child. Never clear that new child's input.
          if let current = ownerStore.subagentDraft(ownerScope) {
            try ownerStore.updateSubagentDraft(ownerScope, message: .init(role: "user",
              content: current.contentRevision == submittedContentRevision && current.message.content == message.content ? "" : current.message.content,
              images: current.message.images.filter { !imageIDs.contains($0.id) },
              files: current.message.files.filter { !fileIDs.contains($0.id) }))
          }
        } else {
          guard token == generation, !Task.isCancelled else { return false }
          try replaceMessage(.init(role: "user",
            content: contentRevision == submittedContentRevision && draft == message.content ? "" : draft,
            images: images.filter { !imageIDs.contains($0.id) }, files: files.filter { !fileIDs.contains($0.id) }))
        }
      } catch {
        if token == generation { self.error = "消息已发送，但无法更新子任务草稿：\(error.localizedDescription)" }
        return token == generation && !Task.isCancelled
      }
      guard token == generation, !Task.isCancelled else { return false }
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
    let token = generation, importToken = UUID(), epoch = draftEpoch, imageCount = images.count, fileCount = files.count
    importGeneration = importToken
    importing = true; attachmentError = nil
    defer { if token == generation, importToken == importGeneration { importing = false } }
    do {
      let sources = try await read()
      guard token == generation, importToken == importGeneration, epoch == draftEpoch, !Task.isCancelled else { return false }
      let imported = try await Task.detached(priority: .userInitiated) {
        try SubagentAttachmentImport.load(sources, root: root, imageCount: imageCount, fileCount: fileCount)
      }.value
      guard token == generation, importToken == importGeneration, epoch == draftEpoch, !Task.isCancelled else { imported.discard(root: root); return false }
      do {
        guard images.count + imported.images.count <= ImageAttachmentStorage.maxCount,
          files.count + imported.files.count <= FileAttachmentStorage.maxCount else {
          throw AgentFailure(message: "每条消息最多添加 8 个文件和 8 张图片。")
        }
        try replaceMessage(.init(role: "user", content: draft,
          images: images + imported.images, files: files + imported.files))
      } catch { imported.discard(root: root); throw error }
      return true
    } catch {
      guard token == generation, importToken == importGeneration, !Task.isCancelled, !(error is CancellationError) else { return false }
      attachmentError = error.localizedDescription; return false
    }
  }

  func chooseAttachments(root: URL, window: NSWindow, imagesOnly: Bool = false) {
    guard selected?.acceptsInput == true, !sending, !importing else { return }
    let token = generation, importToken = importGeneration, epoch = draftEpoch, panel = NSOpenPanel()
    panel.title = imagesOnly ? "添加图片" : "添加附件"
    panel.canChooseDirectories = !imagesOnly; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
    if imagesOnly { panel.allowedContentTypes = [.image] }
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK else { return }
      Task { @MainActor in
        guard let self, self.generation == token, self.importGeneration == importToken, self.draftEpoch == epoch else { return }
        _ = await self.importAttachments(panel.urls.map(SubagentAttachmentSource.file), root: root)
      }
    }
  }
}
