import SwiftUI

/// The reference property grid hides labels below 24rem; labels remain available to accessibility.
struct PullRequestOverviewRowLayout: Layout {
  static let labelThreshold: CGFloat = 384
  var containerInlineInset: CGFloat = 0
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? 384
    let valueWidth = max(0, width - (width + containerInlineInset * 2 >= Self.labelThreshold ? 132 : 28))
    let value = subviews[2].sizeThatFits(.init(width: valueWidth, height: nil))
    return .init(width: width, height: max(30, value.height + 8))
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let wide = bounds.width + containerInlineInset * 2 >= Self.labelThreshold
    let valueX: CGFloat = wide ? 132 : 28
    let icon = subviews[0].sizeThatFits(.init(width: 16, height: nil))
    subviews[0].place(at: .init(x: bounds.minX, y: bounds.minY + 4),
      proposal: .init(width: 16, height: icon.height))
    subviews[1].place(at: .init(x: bounds.minX + 24, y: bounds.minY + 4),
      proposal: .init(width: wide ? 96 : 0, height: wide ? bounds.height - 8 : 0))
    let valueWidth = max(0, bounds.width - valueX)
    let value = subviews[2].sizeThatFits(.init(width: valueWidth, height: nil))
    subviews[2].place(at: .init(x: bounds.minX + valueX, y: bounds.minY + (bounds.height - value.height) / 2),
      proposal: .init(width: valueWidth, height: value.height))
  }
}

struct PullRequestOverviewRow<Content: View>: View {
  let label: String
  let icon: String
  var iconColor: Color = .secondary
  var pullRequestStatus: String? = nil
  @ViewBuilder let content: () -> Content
  var body: some View {
    PullRequestOverviewRowLayout(containerInlineInset: 8) {
      Group {
        if let pullRequestStatus { PullRequestOverviewIcon(status: pullRequestStatus).frame(width: 16, height: 16) }
        else { Image(systemName: icon) }
      }.frame(width: 16, height: 20).foregroundStyle(iconColor).accessibilityHidden(true)
      Text(label).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).clipped()
      content().frame(maxWidth: .infinity, alignment: .leading)
    }.appFont(size: 14)
      .accessibilityElement(children: .contain).accessibilityLabel(label)
  }
}

struct TaskPullRequestOverviewView: View {
  let snapshot: GitHubPRMergeSnapshot?
  let request: GitHubPullRequest
  let loading: Bool
  let error: String?
  let checks: GitHubPRChecksState
  let discussion: GitHubPRDiscussionState
  let reviewers: GitHubPRReviewerState
  let writable: Bool
  let searchReviewers: (String) -> Void
  let retryReviewers: () -> Void
  let applyReviewers: (GitHubPRReviewerAction) -> Void
  var openCode: (() -> Void)? = nil
  var statusState: GitHubPRDetailState? = nil
  var changeStatus: ((GitHubPRStatus) -> Void)? = nil
  private var details: GitHubPRDetails? { snapshot?.details }
  private var presentation: GitHubPROverviewPresentation {
    .init(request: request, metadata: snapshot, loading: loading, error: error,
      discussion: discussion.snapshot, discussionError: discussion.readError,
      checks: checks.snapshot, checksLoading: checks.loading, checksError: checks.error)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      PullRequestOverviewRow(label: "分支", icon: "arrow.triangle.branch") {
        HStack(spacing: 8) {
          HStack(spacing: 8) {
            Text(details?.headRefName ?? request.headRefName).lineLimit(1).truncationMode(.tail)
            Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(.tertiary).accessibilityHidden(true)
            Text(details?.baseRefName ?? request.baseRefName).lineLimit(1).truncationMode(.tail)
          }.help("\(details?.headRefName ?? request.headRefName) → \(details?.baseRefName ?? request.baseRefName)")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(details?.headRefName ?? request.headRefName) → \(details?.baseRefName ?? request.baseRefName)")
          if let added = details?.additions, let removed = details?.deletions {
            if let openCode {
              Button(action: openCode) { stats(added, removed) }.buttonStyle(.plain)
                .help("审查 PR 更改").accessibilityLabel("审查 PR 更改，新增 \(added) 行，删除 \(removed) 行")
                .accessibilityIdentifier("pull-request-overview-open-code")
            } else { stats(added, removed) }
          }
        }
      }.accessibilityIdentifier("pull-request-overview-branch")
      TaskPullRequestReviewersView(state: reviewers, request: request, writable: writable,
        search: searchReviewers, retry: retryReviewers, apply: applyReviewers)
      PullRequestOverviewRow(label: "评论", icon: "bubble.left") {
        readout(presentation.comments, name: "评论")
      }.accessibilityIdentifier("pull-request-overview-comments")
      PullRequestOverviewRow(label: "检查", icon: presentation.checksIcon) {
        readout(presentation.checks, name: "检查")
      }.accessibilityIdentifier("pull-request-overview-checks")
      PullRequestOverviewRow(label: "状态", icon: "", iconColor: statusColor, pullRequestStatus: status) {
        if let statusState, let changeStatus {
          TaskPullRequestStatusView(state: statusState, request: request, writable: writable, select: changeStatus)
        } else { Text(recordedStatus) }
      }.accessibilityIdentifier("pull-request-overview-status")
      if let snapshot, snapshot.isAutoMergeEnabled, details?.state.uppercased() != "MERGED" {
        PullRequestOverviewRow(label: "自动合并", icon: "arrow.triangle.merge") {
          Text("已启用，满足所有要求后将合并分支。").fixedSize(horizontal: false, vertical: true)
        }.accessibilityIdentifier("pull-request-overview-auto-merge")
      }
    }.padding(.horizontal, 8).padding(.bottom, 8).accessibilityIdentifier("pull-request-overview")
  }
  private func stats(_ added: Int, _ removed: Int) -> some View {
    HStack(spacing: 4) {
      Text("+" + added.formatted()).foregroundStyle(.green)
      Text("−" + removed.formatted()).foregroundStyle(.red)
    }.monospacedDigit().fixedSize().accessibilityElement(children: .ignore)
      .accessibilityLabel("新增 \(added) 行，删除 \(removed) 行")
  }
  private func placeholder(_ label: String) -> some View {
    RoundedRectangle(cornerRadius: 4).fill(.primary.opacity(0.06)).frame(width: 96, height: 16)
      .accessibilityLabel(label)
  }
  @ViewBuilder private func readout(_ value: GitHubPROverviewPresentation.Readout, name: String) -> some View {
    switch value {
    case .loading: placeholder("正在读取" + name)
    case .failed: Text("无法读取" + name).foregroundStyle(.secondary)
    case .value(let label, let tone): Text(label).foregroundStyle(color(tone))
    }
  }
  private func color(_ tone: GitHubPROverviewPresentation.Tone) -> Color {
    switch tone { case .normal: .primary; case .secondary: .secondary; case .success: .green; case .pending: .orange; case .failure: .red }
  }
  private var recordedStatus: String {
    switch status { case "merged": "已合并"; case "closed": "已关闭"; case "draft": "草稿"; default: "可供审查" }
  }
  private var status: String {
    switch details?.state.uppercased() ?? request.state?.uppercased() {
    case "MERGED": "merged"
    case "CLOSED": "closed"
    default: (details?.isDraft ?? request.isDraft) ? "draft" : "open"
    }
  }
  private var statusColor: Color {
    switch status { case "merged": .purple; case "closed": .red; default: .secondary }
  }
}

/// Draw the Git nodes natively; macOS has no SF Symbol named arrow.triangle.pullrequest.
private struct PullRequestOverviewIcon: View {
  let status: String
  var body: some View {
    Canvas { context, size in
      let scale = CGAffineTransform(scaleX: size.width / 20, y: size.height / 20)
      var nodes = Path()
      nodes.addEllipse(in: .init(x: 3, y: 3, width: 4, height: 4))
      nodes.addEllipse(in: .init(x: 3, y: 13, width: 4, height: 4))
      nodes.move(to: .init(x: 5, y: 7)); nodes.addLine(to: .init(x: 5, y: 13))
      var branch = Path()
      if status == "merged" {
        branch.move(to: .init(x: 6.7, y: 6))
        branch.addCurve(to: .init(x: 13, y: 11), control1: .init(x: 8, y: 9.5), control2: .init(x: 10.5, y: 11))
        nodes.addEllipse(in: .init(x: 13, y: 9, width: 4, height: 4))
      } else {
        branch.move(to: .init(x: 10, y: 5))
        branch.addCurve(to: .init(x: 15, y: 10.5), control1: .init(x: 15, y: 5), control2: .init(x: 15, y: 7))
        if status == "closed" {
          nodes.move(to: .init(x: 13, y: 13)); nodes.addLine(to: .init(x: 17, y: 17))
          nodes.move(to: .init(x: 17, y: 13)); nodes.addLine(to: .init(x: 13, y: 17))
        } else if status == "draft" {
          nodes.addEllipse(in: .init(x: 13, y: 13, width: 4, height: 4))
        } else {
          nodes.move(to: .init(x: 13, y: 15)); nodes.addLine(to: .init(x: 17, y: 15))
          nodes.move(to: .init(x: 15, y: 13)); nodes.addLine(to: .init(x: 15, y: 17))
        }
      }
      context.stroke(nodes.applying(scale), with: .foreground,
        style: .init(lineWidth: size.width * 1.33 / 20, lineCap: .round, lineJoin: .round))
      context.stroke(branch.applying(scale), with: .foreground,
        style: .init(lineWidth: size.width * 1.33 / 20, lineCap: .round, lineJoin: .round, dash: status == "draft" ? [1, 2] : []))
    }
  }
}
