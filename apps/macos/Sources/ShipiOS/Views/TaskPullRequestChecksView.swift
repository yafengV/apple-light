import SwiftUI

struct TaskPullRequestChecksView: View {
  let state: GitHubPRChecksState
  let openLink: (URL) -> Void
  let retry: () -> Void
  @State private var expanded = true

  var body: some View {
    DisclosureGroup(isExpanded: $expanded) {
      VStack(alignment: .leading, spacing: 10) {
        if state.loading {
          ProgressView("读取检查…").controlSize(.small).frame(maxWidth: .infinity, alignment: .leading)
        } else if let error = state.error {
          Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
            .textSelection(.enabled)
          Button("重试", action: retry)
        } else if let snapshot = state.snapshot {
          if let notice = snapshot.notice {
            HStack {
              Text(notice).foregroundStyle(.secondary)
              Spacer()
              Button("重试", action: retry)
            }
          }
          if snapshot.checks.isEmpty {
            Text(snapshot.complete ? "没有报告任何检查" : "暂无可读取的检查详情")
              .foregroundStyle(.secondary)
          } else {
            VStack(spacing: 0) {
              ForEach(snapshot.sortedChecks) { check in
                if let url = check.validatedLink {
                  Button { openLink(url) } label: { row(check, linked: true) }
                    .buttonStyle(.plain).accessibilityLabel("\(check.name)，\(check.status.label)，打开检查详情")
                } else {
                  row(check, linked: false)
                }
              }
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
          }
        } else {
          Text("等待 PR 状态").foregroundStyle(.secondary)
        }
      }.padding(.top, 8).appFont(.caption)
    } label: {
      Text("检查").appFont(.headline)
    }
    .id("pull-request-checks")
  }

  private func row(_ check: GitHubPRCheck, linked: Bool) -> some View {
    HStack(spacing: 8) {
      Image(systemName: check.status.icon).foregroundStyle(color(check.status))
      Text(check.name).multilineTextAlignment(.leading).lineLimit(3)
        .frame(maxWidth: .infinity, alignment: .leading)
      Text(check.status.label).foregroundStyle(.secondary)
      if linked { Image(systemName: "arrow.up.right").foregroundStyle(.secondary) }
    }.padding(.vertical, 8).contentShape(Rectangle())
      .help([check.name, check.status.label, check.description].compactMap { $0 }.joined(separator: " · "))
  }
  private func color(_ status: GitHubPRCheckStatus) -> Color {
    switch status {
    case .failing: .red
    case .pending: .yellow
    case .passing: .green
    case .neutral, .skipped, .unknown: .secondary
    }
  }
}
