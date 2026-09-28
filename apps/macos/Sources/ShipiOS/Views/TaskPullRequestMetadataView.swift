import AppKit
import SwiftUI

struct TaskPullRequestTitleView: View {
  let editor: GitHubPREditState
  let snapshot: GitHubPRMergeSnapshot?
  let request: GitHubPullRequest
  let writable: Bool
  let save: () -> Void
  let open: (URL) -> Void
  @FocusState private var editFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let draft = editor.title {
        HStack(alignment: .top, spacing: 8) {
          PullRequestTextEditor(text: Binding(get: { editor.title?.text ?? "" },
            set: { editor.change(.title, text: $0) }), field: .title, focus: draft.focus,
            submit: save, cancel: { editor.cancel(.title, request: request) })
            .disabled(editor.busy(request) || !writable)
          Button(action: save) {
            if editor.saving == .title { ProgressView().controlSize(.small) }
            else { Image(systemName: "checkmark") }
          }.buttonStyle(.plain).accessibilityLabel("保存 PR 标题").help("保存标题")
            .disabled(!editor.canSave(.title, snapshot: snapshot, request: request, writable: writable))
          Button { editor.cancel(.title, request: request) } label: { Image(systemName: "xmark") }
            .buttonStyle(.plain).accessibilityLabel("取消标题编辑").help("取消")
            .disabled(editor.busy(request))
        }
        if let error = draft.error { Text(error).appFont(.caption).foregroundStyle(.orange).textSelection(.enabled) }
      } else {
        HStack(alignment: .top, spacing: 8) {
          Text(snapshot?.details.title ?? request.title).appFont(.headline).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
          if let snapshot {
            Button { editor.begin(.title, snapshot: snapshot, request: request, writable: writable) }
              label: { Image(systemName: "pencil") }
              .buttonStyle(.plain).focused($editFocused).help("编辑标题").accessibilityLabel("编辑 PR 标题")
              .disabled(editor.busy(request) || !writable)
          }
          Button {
            guard let url = request.validatedURL else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string)
          } label: { Image(systemName: "link") }
            .buttonStyle(.plain).help("复制 PR 链接").accessibilityLabel("复制 PR 链接")
          Button { if let url = request.validatedURL { open(url) } } label: { Image(systemName: "arrow.up.right") }
            .buttonStyle(.plain).help("在 GitHub 打开").accessibilityLabel("在 GitHub 打开 PR")
        }
      }
    }
    .onChange(of: editor.returnTitleFocus) { _, _ in editFocused = true }
  }
}

struct TaskPullRequestDescriptionView: View {
  let editor: GitHubPREditState
  let snapshot: GitHubPRMergeSnapshot?
  let request: GitHubPullRequest
  let writable: Bool
  let loading: Bool
  let save: () -> Void
  let generate: () -> Void
  let open: (URL) -> Void
  @State private var expanded = true
  @State private var focusProbe = PullRequestEditorFocusProbe()
  @FocusState private var focused: Focus?
  private enum Focus { case action, stop, save }
  private var canEdit: Bool { snapshot.map(GitHubPREditText.canEditBody) == true && writable }

  var body: some View {
    DisclosureGroup(isExpanded: $expanded) {
      VStack(alignment: .leading, spacing: 10) {
        if let draft = editor.body {
          if !editor.generating || !draft.startedFromEmptyView {
            PullRequestTextEditor(text: Binding(get: { editor.body?.text ?? "" },
              set: { editor.change(.body, text: $0) }), field: .body,
              focus: editor.generating || draft.startedFromEmptyView ? nil : draft.focus,
              submit: save, cancel: {}, focusProbe: focusProbe)
              .frame(height: 126).padding(6)
              .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
              .disabled(editor.busy(request) || editor.generating || !canEdit)
          }
          if editor.generating { ProgressView("正在生成描述…").controlSize(.small) }
          if let error = draft.error { Text(error).appFont(.caption).foregroundStyle(.orange).textSelection(.enabled) }
          HStack {
            Button(editor.generating ? "停止" : "取消") { editor.cancel(.body, request: request) }
              .disabled(editor.busy(request)).focused($focused, equals: .stop)
            Button {
              save()
            } label: {
              HStack {
                if editor.saving == .body { ProgressView().controlSize(.small) }
                Text("保存")
              }
            }.focused($focused, equals: .save)
              .disabled(!editor.canSave(.body, snapshot: snapshot, request: request, writable: writable))
            Spacer(minLength: 0)
          }
        } else if loading {
          ProgressView("读取描述…").controlSize(.small)
        } else if let snapshot {
          let text = snapshot.details.body ?? ""
          if GitHubPREditText.trimmed(text).isEmpty {
            Text("没有提供描述").foregroundStyle(.secondary)
          } else {
            MessageMarkdownView(source: text, partPrefix: "pull-request-description", openLink: open)
          }
        } else {
          Text("无法读取描述，请刷新 PR 状态。 ").foregroundStyle(.secondary)
        }
      }.padding(.top, 8)
    } label: {
      HStack {
        Text("描述").appFont(.headline)
        Spacer()
        if canEdit {
          Menu {
            if editor.body == nil {
              Button("编辑描述") { beginEditing() }
            }
            Button("生成描述") { expanded = true; generate() }
          } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).fixedSize().focused($focused, equals: .action)
            .accessibilityLabel("描述操作")
            .disabled(editor.busy(request) || editor.generating)
        }
      }
    }
    .id("pull-request-description")
    .onChange(of: editor.body?.focus) { _, value in if value != nil { expanded = true } }
    .onChange(of: editor.generationFocus) { _, value in if value != nil { focused = .stop } }
    .onChange(of: editor.returnBodyFocus) { _, _ in
      if focused == .stop || focused == .save || focusProbe.mayReturnFocus { focused = .action }
    }
  }
  private func beginEditing() {
    guard let snapshot else { return }
    expanded = true; editor.begin(.body, snapshot: snapshot, request: request, writable: writable)
  }
}
