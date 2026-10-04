import SwiftUI

struct TaskPullRequestStatusView: View {
  let state: GitHubPRDetailState
  let request: GitHubPullRequest
  let writable: Bool
  let select: (GitHubPRStatus) -> Void

  static func items(current: GitHubPRStatus, enabled: Bool) -> [SettingsDropdownItem<GitHubPRStatus>] {
    GitHubPRStatus.options.map {
      .option(.init(value: $0, title: $0.label, selected: $0 == current,
        enabled: enabled && $0.canSelect(from: current)))
    }
  }

  var body: some View {
    if let snapshot = state.snapshot {
      let current = GitHubPRStatus(snapshot.details)
      if snapshot.isAuthor, current != .merged {
        let reason = state.statusDisabledReason(for: request, writable: writable)
        HStack(spacing: 6) {
          if state.statusAction != nil { ProgressView().controlSize(.mini).accessibilityLabel("正在更改 PR 状态") }
          SettingsDropdownMenu(title: current.label, accessibilityLabel: "更改 PR 状态", systemImage: "",
            borderless: true, items: Self.items(current: current, enabled: reason == nil), onSelect: select)
            .fixedSize().disabled(reason != nil).help(reason ?? "更改 PR 状态")
            .accessibilityIdentifier("pull-request-status-menu")
        }
      } else { Text(current.label) }
    } else {
      Text(state.statusRequiresRefresh ? "结果待确认" : state.error != nil && !state.loading ? "无法读取状态" : "正在读取状态")
        .foregroundStyle(.secondary)
    }
  }
}
