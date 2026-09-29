import AppKit
import SwiftUI

struct TaskPullRequestCommentComposer: View {
  @Binding var text: String
  let label: String
  let focus: UUID?
  let enabled: Bool
  let busy: Bool
  let cancel: (() -> Void)?
  var inlineCode = false
  var inputEnabled: Bool? = nil
  var error: String? = nil
  var mentionRequest: GitHubPRMentionRequest? = nil
  let submit: () -> Void
  @State private var mentions = GitHubPRMentionState()
  private var editable: Bool { inputEnabled ?? enabled }
  private var canSubmit: Bool { enabled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      VStack(spacing: 4) {
        PullRequestTextEditor(text: $text, field: .body, focus: focus,
          submit: { if canSubmit { submit() } }, cancel: { if inlineCode && editable { cancel?() } }, accessibilityName: label,
          selectionChanged: { body, range in mentions.setContext(mentionRequest); mentions.select(text: body, range: range) },
          lostFocus: { mentions.blurred() }, handleKey: handleKey, replacement: mentions.replacement, growsWithContent: true)
          .frame(minHeight: 38, maxHeight: 192).padding(6).disabled(!editable)
        HStack {
          if !inlineCode, let login = mentionRequest?.viewer {
            Text(String(login.prefix(1)).uppercased()).appFont(.caption)
              .frame(width: 22, height: 22).background(.quaternary, in: Circle()).accessibilityHidden(true)
          }
          Spacer()
          if inlineCode {
            if let cancel { Button("取消", action: cancel).disabled(!editable) }
            Button(action: submit) {
              HStack { if busy { ProgressView().controlSize(.small) }; Text("评论") }
            }.buttonStyle(.borderedProminent).disabled(!canSubmit)
          } else {
            if let cancel {
              Button(action: cancel) { Image(systemName: "xmark").frame(width: 24, height: 24) }
                .buttonStyle(.plain).disabled(!editable).help(label == "保存更改" ? "取消编辑" : "取消回复")
                .accessibilityLabel("取消")
            }
            Button(action: submit) {
              Group {
                if busy { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.up") }
              }.frame(width: 26, height: 26)
            }.buttonStyle(.borderedProminent).controlSize(.small).clipShape(Circle())
              .disabled(!canSubmit).help(label).accessibilityLabel(label)
          }
        }.padding(.horizontal, 8).padding(.bottom, 8)
      }
      .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
      .background(PullRequestMentionPopover(state: mentions, enabled: editable && mentions.visible))
      if let error { Text(error).appFont(.caption).foregroundStyle(.red).textSelection(.enabled).accessibilityLabel("错误：" + error) }
    }
    .task(id: mentionRequest?.scope) { mentions.setContext(mentionRequest) }
    .onChange(of: editable) { _, value in if !value { mentions.blurred() } }
    .onDisappear { mentions.cancel() }
  }

  private func handleKey(_ event: NSEvent) -> Bool {
    editable && GitHubPRMentionKeyboard.handle(event, state: mentions)
  }
}

struct GitHubPRMentionPicker: View {
  let state: GitHubPRMentionState
  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 2) {
          if state.users.isEmpty {
            if state.loading { ProgressView("正在搜索 GitHub 用户…").controlSize(.small) }
            else if state.error != nil { Text("无法搜索 GitHub 用户").foregroundStyle(.secondary) }
            else { Text("未找到 GitHub 用户").foregroundStyle(.secondary) }
          }
          ForEach(Array(state.users.enumerated()), id: \.element.id) { index, user in
            Button { state.choose(index) } label: {
              HStack(spacing: 8) {
                AsyncImage(url: user.avatarURL.flatMap(URL.init(string:))) { phase in
                  if case .success(let image) = phase { image.resizable().scaledToFill() }
                  else { Text(String(user.login.prefix(1)).uppercased()).frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary) }
                }.frame(width: 24, height: 24).clipShape(Circle())
                Text("@" + user.login).lineLimit(1)
                Spacer(minLength: 0)
              }.padding(.horizontal, 8).frame(height: 32).contentShape(Rectangle())
                .background(state.highlighted == index ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 5))
            }.buttonStyle(.plain).focusable(false).help("提及 @" + user.login)
              .accessibilityLabel("提及 @" + user.login).id(index)
              .onHover { hover in if hover { state.highlight(index) } }
          }
        }.padding(4)
      }
      .onChange(of: state.highlighted) { _, index in if index >= 0 { proxy.scrollTo(index, anchor: nil) } }
    }
    .appFont(.callout).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary)).shadow(radius: 5, y: 2)
    .accessibilityElement(children: .contain).accessibilityLabel("GitHub 用户候选")
  }
}
