import SwiftUI

struct TaskPullRequestReviewersView: View {
  let state: GitHubPRReviewerState
  let request: GitHubPullRequest
  let writable: Bool
  let search: (String) -> Void
  let retry: () -> Void
  let apply: (GitHubPRReviewerAction) -> Void
  @FocusState private var triggerFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      PullRequestOverviewRow(label: "审查者", icon: "person.2") {
        HStack(spacing: 8) {
          if let snapshot = state.snapshot {
            if snapshot.reviewers.isEmpty && !state.canManage(request, writable: writable) {
              Text("无审查者").foregroundStyle(.secondary)
            } else if !snapshot.reviewers.isEmpty {
              ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                  ForEach(snapshot.reviewers) { reviewer in
                    PullRequestReviewerAvatar(reviewer: reviewer)
                      .help(reviewer.label + "，" + reviewer.status.label)
                  }
                }.padding(.vertical, 2).padding(.trailing, 2)
              }.frame(maxWidth: CGFloat(snapshot.reviewers.count) * 28)
                .fixedSize(horizontal: false, vertical: true)
            }
            if snapshot.canManage && writable {
              Button { state.showingPicker = true } label: {
                if snapshot.reviewers.isEmpty { Label("请求", systemImage: "plus") }
                else { Image(systemName: "plus") }
              }.buttonStyle(.plain).focused($triggerFocused)
                .disabled(!state.canManage(request, writable: writable))
                .accessibilityLabel(snapshot.reviewers.isEmpty ? "请求审查者" : "管理审查者")
                .popover(isPresented: Binding(get: { state.showingPicker }, set: {
                  if $0 { state.showingPicker = true } else { state.closePicker() }
                }), arrowEdge: .bottom) {
                  PullRequestReviewerPicker(state: state, request: request, writable: writable,
                    search: search, apply: apply)
                    .onDisappear { state.closePicker(); triggerFocused = true }
                }
            }
          } else if state.error != nil { Text("无法读取审查者").foregroundStyle(.secondary) }
          else {
            RoundedRectangle(cornerRadius: 4).fill(.primary.opacity(0.06)).frame(width: 96, height: 16)
              .accessibilityLabel("正在读取审查者")
          }
          if state.busy { ProgressView().controlSize(.small).accessibilityLabel("正在更新审查者") }
        }
      }
      if let error = state.error {
        HStack(alignment: .top) {
          Text(error).foregroundStyle(.orange).textSelection(.enabled).appFont(.caption)
          Button("重试") { retry() }.buttonStyle(.plain).disabled(state.loading || state.busy)
        }
      }
    }.accessibilityIdentifier("pull-request-reviewers")
  }
}

struct PullRequestReviewerPicker: View {
  let state: GitHubPRReviewerState
  let request: GitHubPullRequest
  let writable: Bool
  let search: (String) -> Void
  let apply: (GitHubPRReviewerAction) -> Void
  @FocusState private var searchFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("请求审查…", text: Binding(get: { state.query }, set: search))
          .textFieldStyle(.plain).focused($searchFocused).accessibilityLabel("搜索 GitHub 用户")
          .onKeyPress(.downArrow) { state.move(1); return .handled }
          .onKeyPress(.upArrow) { state.move(-1); return .handled }
          .onSubmit { if let item = state.options.first(where: { $0.id == state.highlighted }) { choose(item) } }
      }.padding(8)
      Divider()
      if state.searching { ProgressView("正在搜索…").controlSize(.small).padding(8) }
      else if state.searchError != nil {
        HStack {
          Text("无法搜索 GitHub 用户").foregroundStyle(.orange)
          Spacer()
          Button("重试") { search(state.query) }
        }.padding(8)
      } else if state.options.isEmpty {
        Text(state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ? "按姓名或 GitHub 用户名搜索" : "未找到用户").foregroundStyle(.secondary).padding(8)
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(spacing: 2) {
              ForEach(state.options) { item in
                Button { choose(item) } label: {
                  HStack(spacing: 8) {
                    PullRequestReviewerAvatar(reviewer: item, showsStatus: false)
                    VStack(alignment: .leading, spacing: 2) {
                      Text(item.label).lineLimit(1)
                      if state.snapshot?.reviewers.contains(where: { $0.id == item.id }) == true, !item.requested {
                        Text("审查已提交").appFont(.caption).foregroundStyle(.secondary)
                      }
                    }
                    Spacer(minLength: 0)
                    if state.isSelected(item) { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                  }.padding(8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    .background(state.highlighted == item.id ? Color.primary.opacity(0.06) : .clear,
                      in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain).id(item.id)
                  .disabled(!state.canManage(request, writable: writable))
                  .accessibilityValue(state.isSelected(item) ? "已选中" : "未选中")
                  .help(item.requested ? "移除待审查请求" : state.isSelected(item) && !state.selected.contains(where: { "user:" + $0.id == item.id }) ? "审查已提交" : "选择审查者")
              }
            }
          }.frame(maxHeight: 280)
            .onChange(of: state.highlighted) { _, id in if let id { proxy.scrollTo(id) } }
        }
      }
      if !state.selected.isEmpty {
        Button("请求") {
          let logins = state.selected.map(\.login)
          state.closePicker(); apply(.request(logins))
        }.buttonStyle(.bordered).frame(maxWidth: .infinity)
          .disabled(!state.canManage(request, writable: writable))
          .accessibilityIdentifier("request-selected-reviewers")
      }
    }.padding(6).frame(width: 300).appFont(.callout)
      .task { searchFocused = true; state.highlighted = state.options.first?.id }
      .onExitCommand { state.closePicker() }
  }
  private func choose(_ item: GitHubPRReviewer) {
    guard state.canManage(request, writable: writable) else { return }
    if item.requested { apply(.remove(item)) }
    else { state.toggle(item) }
  }
}

private struct PullRequestReviewerAvatar: View {
  let reviewer: GitHubPRReviewer
  var showsStatus = true
  private var statusColor: Color {
    switch reviewer.status { case .waiting: .yellow; case .approved: .green; case .changesRequested: .red }
  }
  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      Group {
        if reviewer.kind == .team { Image(systemName: "person.2.fill").font(.system(size: 11)) }
        else if let raw = reviewer.avatarURL, let url = URL(string: raw), url.scheme == "https" {
          AsyncImage(url: url) { image in image.resizable().scaledToFill() }
            placeholder: { Image(systemName: "person.fill").font(.system(size: 12)) }
        } else { Image(systemName: "person.fill").font(.system(size: 12)) }
      }.frame(width: 20, height: 20).background(.quaternary).clipShape(Circle())
      if showsStatus {
        Circle().fill(statusColor).frame(width: 8, height: 8)
          .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1)).offset(x: 2, y: 2)
      }
    }.accessibilityElement(children: .ignore)
      .accessibilityLabel(reviewer.label + (reviewer.kind == .team ? " 团队" : "")
        + (showsStatus ? "，" + reviewer.status.label : ""))
  }
}
