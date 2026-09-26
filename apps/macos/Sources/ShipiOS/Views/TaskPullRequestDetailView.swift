import AppKit
import SwiftUI

struct TaskPullRequestDetailView: View {
  let request: GitHubPullRequest
  let root: URL
  let openExternal: (URL) -> Void
  let onRefresh: (GitHubPullRequest) -> Void
  let back: () -> Void
  let close: () -> Void

  @State private var details: GitHubPRDetails?
  @State private var loading = false
  @State private var error: String?

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Button(action: back) { Image(systemName: "chevron.left") }
          .buttonStyle(.plain).help("返回摘要").accessibilityLabel("返回摘要")
        Text("Pull request #\(request.number)").appFont(.headline).lineLimit(1)
        Spacer(minLength: 0)
        Button(action: close) { Image(systemName: "xmark") }
          .buttonStyle(.plain).help("关闭摘要").accessibilityLabel("关闭摘要")
      }.padding(.horizontal, 16).padding(.vertical, 13)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          Text(details?.title ?? request.title).appFont(.headline).textSelection(.enabled)
          HStack {
            Label(details?.statusLabel ?? (request.isDraft ? "草稿" : "最后记录为开放"),
              systemImage: details?.state.uppercased() == "MERGED" ? "checkmark.circle.fill"
                : "arrow.triangle.pullrequest")
            Spacer()
            if loading { ProgressView().controlSize(.small) }
          }.appFont(.caption).foregroundStyle(.secondary)
          Text("\(details?.headRefName ?? request.headRefName) → \(details?.baseRefName ?? request.baseRefName)")
            .appFont(.caption).foregroundStyle(.secondary).textSelection(.enabled)
          if let details {
            if let decision = details.reviewDecision, !decision.isEmpty {
              LabeledContent("审查", value: reviewLabel(decision))
            }
            let checks = details.checkSummary
            if checks.passed + checks.failed + checks.pending > 0 {
              LabeledContent("检查", value:
                "\(checks.passed) 通过 · \(checks.failed) 失败 · \(checks.pending) 进行中")
            }
            if let mergeable = details.mergeable, mergeable.uppercased() == "CONFLICTING" {
              Label("存在合并冲突", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            }
            if let body = details.body, !body.isEmpty {
              Divider()
              MessageMarkdownView(source: body, partPrefix: "pull-request") { url in
                openExternal(url)
              }
            }
          }
          if let error {
            Label(error, systemImage: "exclamationmark.circle")
              .appFont(.caption).foregroundStyle(.orange).textSelection(.enabled)
          }
          HStack {
            Button("刷新状态") { Task { await refresh() } }.disabled(loading)
            Spacer()
            Menu {
              Button("复制链接") {
                guard let url = request.validatedURL else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
              }
              Button("在浏览器中打开") {
                if let url = request.validatedURL { openExternal(url) }
              }
            } label: { Image(systemName: "ellipsis") }
              .menuStyle(.borderlessButton)
              .accessibilityLabel("PR 更多操作")
          }
        }
        .appFont(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
      }
    }
    .frame(width: 316)
    .background(.regularMaterial)
    .task(id: request.url) { await refresh() }
  }

  private func refresh() async {
    guard !loading else { return }
    loading = true
    error = nil
    defer { loading = false }
    do {
      let updated = try await GitHubPRService().details(for: request, at: root)
      guard !Task.isCancelled else { return }
      details = updated
      onRefresh(updated.recorded(updating: request))
    } catch {
      guard !Task.isCancelled else { return }
      self.error = error.localizedDescription
    }
  }

  private func reviewLabel(_ decision: String) -> String {
    switch decision.uppercased() {
    case "APPROVED": "已批准"
    case "CHANGES_REQUESTED": "要求修改"
    case "REVIEW_REQUIRED": "等待审查"
    default: decision
    }
  }
}
