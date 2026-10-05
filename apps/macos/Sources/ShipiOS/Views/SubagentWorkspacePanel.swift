import SwiftUI

/// Selection and drafts belong to this panel/window, while runtime identities
/// and actual child status remain owned by the parent task.
struct SubagentWorkspacePanel: View {
  let store: WorkspaceStore
  let taskID: String
  @State private var detail = SubagentDetailState()
  @State private var reload = 0
  private var agents: [CodexSubagent] { store.subagents(taskID: taskID) }
  private var current: CodexSubagent? { agents.first { $0.id == detail.selected?.id } }
  private var parentRoot: String? { store.library.tasks.first { $0.id == taskID }?.codexThreadID }
  private var refreshKey: String {
    [detail.selected?.id ?? "", String(reload), current?.status.rawValue ?? "",
      String(current?.loaded ?? false)].joined(separator: ":")
  }
  private var sendDisabled: Bool {
    detail.sending || detail.loading || detail.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || (current?.working == true && detail.transcript.activeTurnID == nil)
  }

  var body: some View {
    VStack(spacing: 0) {
      if let selected = detail.selected {
        header(selected)
        Divider()
        SubagentTranscriptView(transcript: detail.transcript, loading: detail.loading, error: detail.error,
          retry: { reload += 1 }, openLink: openLink)
        if current?.acceptsInput == true && parentRoot == selected.rootThreadID {
          composer
        }
      } else {
        SubagentsPanelView(agents: agents, onSelect: { detail.select($0) })
      }
    }
    .task(id: refreshKey) {
      guard detail.selected != nil else { return }
      repeat {
        await detail.load(using: read)
        guard !Task.isCancelled, detail.selected != nil else { return }
        // Keep observing this actual loaded child, including turns submitted
        // from a different window. No input is required to read cold history.
        guard current?.working == true, detail.error == nil else { return }
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
      } while !Task.isCancelled
    }
    .onChange(of: parentRoot) { _, _ in detail.select(nil) }
    .onChange(of: current) { _, agent in if let agent { detail.update(agent) } }
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
    HStack(alignment: .bottom, spacing: 8) {
      TextEditor(text: $detail.draft).frame(minHeight: 40, maxHeight: 100)
        .appContentFont(size: 14).accessibilityLabel("子任务消息")
        .accessibilityIdentifier("subagent-composer")
      Button(current?.working == true ? "引导" : "发送") { Task { await send() } }
        .disabled(sendDisabled).accessibilityIdentifier("subagent-send")
    }.padding(12)
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
    return try await store.codexTransport.readSubagentHistory(taskID: taskID,
      rootThreadID: agent.rootThreadID, childThreadID: agent.threadID)
  }

  private func send() async {
    guard let current, current.acceptsInput, parentRoot == current.rootThreadID else { return }
    if await detail.send(working: current.working, using: { agent, text, turn in
      try await store.codexTransport.submitSubagent(taskID: taskID, rootThreadID: agent.rootThreadID,
        childThreadID: agent.threadID, text: text, expectedTurnID: turn)
    }) { reload += 1 }
  }
}

struct SubagentTranscriptView: View {
  let transcript: SubagentTranscript
  let loading: Bool
  let error: String?
  let retry: () -> Void
  let openLink: (URL) -> Void
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
              Text(entry.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .padding(12).background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            case .tool, .reasoning:
              DisclosureGroup(entry.title ?? "工具") {
                Text(entry.text).textSelection(.enabled).font(.system(size: 12, design: .monospaced))
                  .frame(maxWidth: .infinity, alignment: .leading)
              }.foregroundStyle(.secondary)
            case .notice: Text(entry.text).foregroundStyle(.secondary).appFont(size: 12)
            }
          }.accessibilityIdentifier("subagent-entry:" + entry.id)
        }
      }.appContentFont(size: 14).padding(20).frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity)
    }.accessibilityIdentifier("subagent-transcript")
  }
}
