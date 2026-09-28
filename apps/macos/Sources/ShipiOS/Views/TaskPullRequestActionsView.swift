import SwiftUI

struct TaskPullRequestActionsView: View {
  let state: GitHubPRDetailState
  let request: GitHubPullRequest
  let writable: Bool
  let apply: (GitHubPRMergeAction) -> Void

  var body: some View {
    let mergeReason = state.mergeDisabledReason(for: request, writable: writable)
    let autoReason = state.autoMergeDisabledReason(for: request, writable: writable)
    HStack(spacing: 6) {
      if let action = state.action {
        ProgressView().controlSize(.small)
        Text(action.progressLabel).appFont(.callout)
      } else if state.snapshot?.isAutoMergeEnabled == true {
        Button("停用自动合并") { apply(.autoMerge(enabled: false, method: state.selectedMethod)) }
          .disabled(autoReason != nil).help(autoReason ?? "满足所有要求后将自动合并。")
      } else {
        Button("合并…") { state.openConfirmation(for: request, writable: writable) }
          .disabled(mergeReason != nil).help(mergeReason ?? "选择合并方式并确认。")
          .buttonStyle(.borderedProminent)
        Menu {
          Button("合并…") { state.openConfirmation(for: request, writable: writable) }
            .disabled(mergeReason != nil)
          Button("启用自动合并") { apply(.autoMerge(enabled: true, method: state.selectedMethod)) }
            .disabled(autoReason != nil)
        } label: { Image(systemName: "chevron.down") }
          .menuStyle(.borderlessButton).fixedSize()
          .accessibilityLabel("PR 合并操作")
      }
      Spacer(minLength: 0)
    }
  }
}

struct TaskPullRequestMergeConfirmation: View {
  @Bindable var state: GitHubPRDetailState
  let request: GitHubPullRequest
  let writable: Bool
  let confirm: () -> Void

  var body: some View {
    let busy = state.busy(for: request)
    VStack(alignment: .leading, spacing: 18) {
      Text("合并 Pull Request").appFont(.title2)
      Text("GitHub 只会在当前显示的头提交仍然匹配时合并。")
        .appFont(.callout).foregroundStyle(.secondary)
      Text("#\(request.number) · \(state.snapshot?.details.title ?? request.title)")
        .appFont(.headline).lineLimit(3)
      if let revision = state.snapshot?.headRevision {
        Text(revision).appFont(.caption, design: .monospaced).textSelection(.enabled)
      }
      if let methods = state.snapshot?.allowedMethods {
        if methods.count > 1 {
          Picker("合并方式", selection: Binding(get: { state.selectedMethod }, set: state.selectMethod)) {
            // The public Codex confirmation lists squash before merge commit.
            ForEach([GitHubPRMergeMethod.squash, .merge].filter(methods.contains)) { method in
              Text(method.label).tag(method)
            }
          }.pickerStyle(.segmented).disabled(busy)
        } else {
          Text("合并方式：\(state.selectedMethod.label)").appFont(.callout)
        }
      }
      if let error = state.error {
        Label(error, systemImage: "exclamationmark.circle").appFont(.callout)
          .foregroundStyle(.orange).textSelection(.enabled)
      }
      if let reason = state.mergeDisabledReason(for: request, writable: writable), !busy {
        Text(reason).appFont(.caption).foregroundStyle(.secondary)
      }
      HStack {
        Spacer()
        Button("取消") { state.showingMergeConfirmation = false }
          .keyboardShortcut(.cancelAction).disabled(busy)
        Button(action: confirm) {
          if busy { ProgressView().controlSize(.small) }
          Text(busy ? "正在合并…" : state.selectedMethod.confirmationLabel)
        }
        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        .disabled(state.mergeDisabledReason(for: request, writable: writable) != nil)
      }
    }
    .padding(24).frame(width: 440)
    .interactiveDismissDisabled(busy)
  }
}
