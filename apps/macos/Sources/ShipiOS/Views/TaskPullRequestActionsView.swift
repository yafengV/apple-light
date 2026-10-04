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
