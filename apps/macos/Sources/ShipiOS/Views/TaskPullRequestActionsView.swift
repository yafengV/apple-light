import SwiftUI

struct TaskPullRequestActionsView: View {
  let state: GitHubPRDetailState
  let request: GitHubPullRequest
  let writable: Bool
  let apply: (GitHubPRMergeAction) -> Void

  private var presentation: GitHubPRMergePresentation {
    .init(snapshot: state.snapshot, action: state.action,
      mergeReason: state.mergeDisabledReason(for: request, writable: writable),
      autoReason: state.autoMergeDisabledReason(for: request, writable: writable))
  }

  var body: some View {
    let presentation = presentation
    Group {
      switch presentation.mode {
      case .hidden: EmptyView()
      case .progress(let title):
        HStack(spacing: 8) { ProgressView().controlSize(.small); Text(title) }
          .frame(maxWidth: .infinity, minHeight: 44)
          .accessibilityElement(children: .ignore).accessibilityLabel(title)
          .accessibilityIdentifier("pull-request-merge-progress")
      case .disableAuto:
        Button { activate(.disableAuto) } label: {
          Text("停用自动合并").frame(maxWidth: .infinity, minHeight: 44)
        }.buttonStyle(.plain).disabled(presentation.autoReason != nil)
          .help(presentation.autoReason ?? "满足所有要求后将自动合并。")
          .accessibilityIdentifier("pull-request-disable-auto-merge")
      case .disabled(let reason):
        HStack(spacing: 8) {
          Image(systemName: "arrow.triangle.merge").accessibilityHidden(true)
          Text("合并")
          Image(systemName: "chevron.down").font(.system(size: 9)).accessibilityHidden(true)
        }.frame(maxWidth: .infinity, minHeight: 44).foregroundStyle(.secondary)
          .accessibilityHidden(true)
          .overlay { PullRequestUnavailableMergeControl(reason: reason) }
          .accessibilityIdentifier("pull-request-merge-unavailable")
      case .menu:
        HStack(spacing: 8) {
          Image(systemName: "arrow.triangle.merge")
          Text("合并")
          Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, minHeight: 44).accessibilityHidden(true)
          .overlay {
            SettingsDropdownMenu(title: "合并", accessibilityLabel: "PR 合并操作", systemImage: "",
              borderless: true, transparent: true, items: presentation.items, onSelect: activate)
              .frame(maxWidth: .infinity, minHeight: 44)
              .accessibilityIdentifier("pull-request-merge-menu")
          }
      }
    }.background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.12)))
  }

  private func activate(_ action: GitHubPRMergePresentation.Selection) {
    guard let action = presentation.action(for: action, method: state.selectedMethod) else { return }
    switch action {
    case .confirm: state.openConfirmation(for: request, writable: writable)
    case .apply(let action): apply(action)
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
