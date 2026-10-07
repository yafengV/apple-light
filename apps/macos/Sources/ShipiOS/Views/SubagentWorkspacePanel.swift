import SwiftUI

/// Selection/loading belong to this panel; drafts belong to the child conversation.
/// Runtime identities and actual child status remain owned by the parent task.
struct SubagentWorkspacePanel: View {
  let store: WorkspaceStore
  let taskID: String
  @State private var detail = SubagentDetailState()
  @State private var reload = 0
  @State private var discoveryRetry = 0
  @State private var discoveryToken = UUID()
  @State private var discoveryError: String?
  @State private var previewFile: FileAttachment?
  @AppStorage(ComposerSendShortcut.storageKey) private var shortcutRaw = ComposerSendShortcut.commandEnter.rawValue
  private var agents: [CodexSubagent] { store.subagents(taskID: taskID) }
  private var current: CodexSubagent? { agents.first { $0.id == detail.selected?.id } }
  private var live: SubagentLiveState? { detail.selected.flatMap { store.subagentLiveStates[$0.id] } }
  private var parentRoot: String? { store.library.tasks.first { $0.id == taskID }?.codexThreadID }
  private var refreshKey: String {
    [detail.selected?.id ?? "", String(reload), current?.status.rawValue ?? "",
      String(current?.loaded ?? false)].joined(separator: ":")
  }
  private var sendDisabled: Bool {
    detail.sending || detail.loading || detail.importing || !detail.hasInput
      || (current?.working == true && detail.transcript.activeTurnID == nil)
  }

  var body: some View {
    VStack(spacing: 0) {
      if let selected = detail.selected {
        header(selected)
        Divider()
        SubagentTranscriptView(transcript: detail.transcript.attaching(store.subagentSubmissions(taskID: taskID,
          rootThreadID: selected.rootThreadID, childThreadID: selected.threadID), root: store.dataRoot), loading: detail.loading, error: detail.error ?? live?.error,
          retry: { reload += 1 }, openLink: openLink,
          approvalStatus: { live?.error == nil ? live?.approvals[$0] : nil }, approvalBusy: { store.subagentApprovalBusy.contains($0) },
          approvalError: { store.subagentApprovalErrors[$0] }, approve: { request, choice in
            guard let current else { return }
            Task { await store.resolveSubagentApproval(taskID: taskID, agent: current, request: request, choice: choice) }
          }, elicitationStatus: { live?.error == nil ? live?.elicitations[$0] : nil },
          elicitationBusy: { store.subagentElicitationBusy.contains($0) }, elicitationError: { store.subagentElicitationErrors[$0] },
          openVerificationURL: { url in
            store.performMessageLinkAction(.openExternal, url: url, ownerRunID: store.library.tasks.first { $0.id == taskID }?.runIDs.last)
          }, elicit: { request, choice, content in
            guard let current else { return }
            Task { await store.resolveSubagentElicitation(taskID: taskID, agent: current, request: request, choice: choice, content: content) }
          }, store: store, onPreviewFile: { previewFile = $0 })
        if current?.acceptsInput == true && parentRoot == selected.rootThreadID {
          composer
        }
      } else {
        if let discoveryError {
          HStack {
            Text(discoveryError).appFont(size: 12).foregroundStyle(.secondary)
            Spacer()
            Button("重新加载") { discoveryRetry += 1 }.buttonStyle(.plain)
          }.padding(12).accessibilityIdentifier("subagents-discovery-error")
        }
        SubagentsPanelView(agents: agents, onSelect: { detail.select($0) })
      }
    }
    .task(id: (parentRoot ?? "") + ":" + String(discoveryRetry)) {
      let token = UUID(); discoveryToken = token; discoveryError = nil
      guard let root = parentRoot else { return }
      do { try await store.refreshSubagents(taskID: taskID, expectedRoot: root) }
      catch {
        guard !Task.isCancelled, discoveryToken == token, parentRoot == root else { return }
        discoveryError = error.localizedDescription
      }
    }
    .task(id: refreshKey) {
      guard detail.selected != nil else { return }
      detail.updateLive(live)
      repeat {
        await detail.load(using: read)
        guard !Task.isCancelled, detail.selected != nil else { return }
        // Keep observing this actual loaded child, including turns submitted
        // from a different window. No input is required to read cold history.
        guard current?.working == true, detail.error == nil else { return }
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
      } while !Task.isCancelled
    }
    .onChange(of: live) { _, state in detail.updateLive(state) }
    .onAppear { detail.bindDrafts(to: store, taskID: taskID) }
    .onDisappear { detail.cancelPendingAttachmentImport() }
    .onChange(of: parentRoot) { _, _ in detail.select(nil) }
    .onChange(of: current) { _, agent in if let agent { detail.update(agent) } }
    .sheet(item: $previewFile) { file in FileAttachmentPreview(file: file, root: store.dataRoot) }
  }

  private func header(_ selected: CodexSubagent) -> some View {
    HStack(spacing: 8) {
      Button { detail.select(nil) } label: { Image(systemName: "chevron.left").frame(width: 24, height: 24) }
        .buttonStyle(.plain).accessibilityLabel("返回子任务列表").accessibilityIdentifier("subagent-back")
      SubagentAvatar(agent: selected)
      Text(selected.displayName).lineLimit(1).appFont(size: 14, weight: .medium)
      Spacer(minLength: 8)
      if let title = modelTitle(selected) {
        Text(title).appFont(size: 12).foregroundStyle(.secondary).lineLimit(1)
      }
    }.padding(.horizontal, 16).frame(minHeight: 40)
  }

  private func modelTitle(_ selected: CodexSubagent) -> String? {
    guard let model = current?.model ?? selected.model else { return nil }
    guard let effort = current?.reasoningEffort ?? selected.reasoningEffort else { return model }
    return model + " · " + (AgentReasoningEfforts.titles[effort] ?? effort)
  }

  private var composer: some View {
    SubagentComposerView(text: $detail.draft, plainTextMode: store.composerPlainTextMode,
      sendShortcut: UserDefaults.standard.object(forKey: ComposerSendShortcut.storageKey) == nil
        ? ComposerSendShortcut.stored() : ComposerSendShortcut(rawValue: shortcutRaw) ?? .commandEnter,
      working: current?.working == true, sending: detail.sending,
      stopping: current.flatMap { store.subagentStopBusy[$0.id] } != nil,
      canSend: !sendDisabled,
      canStop: current?.working == true && detail.transcript.activeTurnID != nil,
      stopError: current.flatMap { store.subagentStopErrors[$0.id] },
      previousPrompt: detail.transcript.entries.last(where: { $0.kind == .user })?.text,
      send: { Task { await send() } }, stop: {
        guard let current, let turn = detail.transcript.activeTurnID else { return }
        Task { await store.stopSubagent(taskID: taskID, agent: current, expectedTurnID: turn) }
      }, store: store, detail: detail, onPreviewFile: { previewFile = $0 }).id(detail.selected?.id)
  }

  private func openLink(_ url: URL) {
    store.openMessageLink(url, project: nil,
      ownerRunID: store.library.tasks.first { $0.id == taskID }?.runIDs.last,
      click: WebLinkClick(event: NSApp.currentEvent))
  }

  private func read(_ agent: CodexSubagent) async throws -> [JSONValue] {
    guard parentRoot == agent.rootThreadID, agents.contains(where: { $0.id == agent.id }) else {
      throw AgentFailure(message: "子任务所属会话已变化，请返回列表。")
    }
    if current?.loaded != true { try await store.prepareSubagent(taskID: taskID, agent: agent) }
    return try await store.codexTransport.readSubagentHistory(taskID: taskID,
      rootThreadID: agent.rootThreadID, childThreadID: agent.threadID)
  }

  private func send() async {
    guard let current, current.acceptsInput, parentRoot == current.rootThreadID else { return }
    if await detail.sendMessage(working: current.working, using: { agent, message, turn in
      try await store.codexTransport.submitSubagent(taskID: taskID, rootThreadID: agent.rootThreadID,
        childThreadID: agent.threadID, text: message.content, expectedTurnID: turn,
        images: message.images, files: message.files)
    }) { reload += 1 }
  }
}

struct SubagentTranscriptView: View {
  let transcript: SubagentTranscript
  let loading: Bool
  let error: String?
  let retry: () -> Void
  let openLink: (URL) -> Void
  var approvalStatus: (String) -> SubagentApprovalStatus? = { _ in nil }
  var approvalBusy: (String) -> Bool = { _ in false }
  var approvalError: (String) -> String? = { _ in nil }
  var approve: (SubagentApprovalRequest, Int) -> Void = { _, _ in }
  var elicitationStatus: (String) -> SubagentElicitationStatus? = { _ in nil }
  var elicitationBusy: (String) -> Bool = { _ in false }
  var elicitationError: (String) -> String? = { _ in nil }
  var openVerificationURL: ((URL) -> Void)? = nil
  var elicit: (SubagentElicitationRequest, SubagentElicitationRequest.Choice, JSONValue?) -> Void = { _, _, _ in }
  var store: WorkspaceStore? = nil
  var onPreviewFile: ((FileAttachment) -> Void)? = nil
  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 24) {
        if loading { ProgressView("正在加载子会话…").frame(maxWidth: .infinity) }
        if let error {
          VStack(alignment: .leading, spacing: 8) {
            Text(error).foregroundStyle(.secondary)
            Button("重新加载", action: retry)
          }.accessibilityIdentifier("subagent-history-error")
        }
        if !loading && error == nil && transcript.entries.isEmpty {
          Text("子任务还没有会话记录").foregroundStyle(.secondary)
        }
        ForEach(transcript.entries) { entry in
          Group {
            switch entry.kind {
            case .assistant:
              MessageMarkdownView(source: entry.text, partPrefix: "subagent:" + entry.id, openLink: openLink)
            case .user:
              VStack(alignment: .leading, spacing: 10) {
                if let store {
                  if entry.hasAttachmentMetadata { ImageAttachmentsView(store: store, images: entry.images) }
                  else if !entry.localImagePaths.isEmpty { SubagentHistoryImagesView(store: store, paths: entry.localImagePaths) }
                  FileAttachmentsView(store: store, files: entry.files, onPreview: onPreviewFile)
                }
                if !entry.text.isEmpty { Text(entry.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
              }
                .padding(12).background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            case .tool, .reasoning:
              DisclosureGroup(entry.title ?? "工具") {
                Text(entry.text).textSelection(.enabled).font(.system(size: 12, design: .monospaced))
                  .frame(maxWidth: .infinity, alignment: .leading)
              }.foregroundStyle(.secondary)
            case .approval:
              if let request = entry.approval {
                SubagentApprovalCard(request: request, status: approvalStatus(request.id),
                  busy: approvalBusy(request.id), error: approvalError(request.id),
                  choose: { approve(request, $0) })
              }
            case .elicitation:
              if let request = entry.elicitation {
                SubagentElicitationCard(request: request, status: elicitationStatus(request.id), busy: elicitationBusy(request.id),
                  error: elicitationError(request.id), openURL: openVerificationURL ?? openLink, submit: { elicit(request, $0, $1) })
              }
            case .notice: Text(entry.text).foregroundStyle(.secondary).appFont(size: 12)
            }
          }.accessibilityIdentifier("subagent-entry:" + entry.id)
        }
      }.appContentFont(size: 14).padding(20).frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity)
    }.accessibilityIdentifier("subagent-transcript")
  }
}
