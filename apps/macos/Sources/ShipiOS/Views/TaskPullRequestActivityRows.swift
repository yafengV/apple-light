import SwiftUI

struct TaskPullRequestActivityEventView: View {
  let event: GitHubPRActivityEvent
  private var icon: String {
    switch event.kind {
    case "approved": "checkmark.circle"
    case "changes_requested": "exclamationmark.bubble"
    case "merged": "arrow.triangle.merge"
    default: "arrow.triangle.pull"
    }
  }
  private var color: Color {
    switch event.kind { case "approved", "opened": .green; case "changes_requested": .red; default: .purple }
  }
  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: icon).foregroundStyle(color).frame(width: 24, height: 24)
        .background(.quaternary, in: Circle()).accessibilityHidden(true)
      Text((event.author.isEmpty || event.author == "未知作者" ? "某人" : event.author) + " " + event.text)
        .appFont(size: 16, weight: .medium).frame(maxWidth: .infinity, alignment: .leading)
      TaskPullRequestActivityDateView(value: event.createdAt)
    }.padding(.horizontal, 12).padding(.vertical, 10)
      .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
  }
}

struct TaskPullRequestCommitGroupView: View {
  let group: GitHubPRCommitGroup
  let open: (URL) -> Void
  @State private var expanded = false
  @State private var hovered = false
  @FocusState private var focusedControl: String?
  @Environment(\.appAppearance) private var appearance
  var body: some View {
    Group {
      if group.commits.count == 1, let commit = group.commits.first {
        commitRow(commit, grouped: false)
      } else if !group.commits.isEmpty {
        VStack(spacing: 0) {
          Button { expanded.toggle() } label: {
            HStack(spacing: 10) {
              commitIcon
              HStack(spacing: 6) {
                Text("\(group.commits.count) 个提交").appFont(size: 16, weight: .medium)
                Image(systemName: "chevron.right").appFont(size: 10).foregroundStyle(.tertiary)
                  .rotationEffect(.degrees(expanded ? 90 : 0)).opacity(hovered || focusedControl != nil ? 1 : 0)
                  .animation(appearance.shouldReduceMotion ? nil : .easeInOut(duration: 0.15), value: expanded)
              }.frame(maxWidth: .infinity, alignment: .leading)
              TaskPullRequestActivityDateView(value: group.createdAt)
            }.contentShape(Rectangle()).padding(.horizontal, 12).padding(.vertical, 10)
          }.buttonStyle(.plain).focused($focusedControl, equals: "summary").onHover { hovered = $0 }
            .onKeyPress(.return) { expanded.toggle(); return .handled }
            .accessibilityLabel("\(expanded ? "收起" : "展开") \(group.commits.count) 个提交")
            .accessibilityValue(expanded ? "已展开" : "已收起")
          if expanded {
            Divider()
            ForEach(group.commits) { commit in commitRow(commit, grouped: true) }
          }
        }.background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
          .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
      }
    }.onChange(of: group.commits.count) { _, count in if count <= 1 { expanded = false } }
  }
  private var commitIcon: some View {
    HStack(spacing: 0) {
      Rectangle().frame(width: 4, height: 1.5)
      Circle().stroke(lineWidth: 1.5).frame(width: 7, height: 7)
      Rectangle().frame(width: 4, height: 1.5)
    }.foregroundStyle(.secondary).frame(width: 24, height: 24)
      .background(.quaternary, in: Circle()).accessibilityHidden(true)
  }
  @ViewBuilder private func commitRow(_ commit: GitHubPRActivityEvent, grouped: Bool) -> some View {
    HStack(spacing: 10) {
      commitIcon
      Text(commit.text).appFont(size: 16, weight: .medium).lineLimit(1).truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
      if let raw = commit.url, let url = TaskPullRequestCommentView.link(raw) {
        Button { open(url) } label: { Text(String(commit.id.prefix(7))).monospaced() }
          .buttonStyle(.plain).foregroundStyle(.secondary).appFont(size: 14)
          .focused($focusedControl, equals: commit.id)
          .onKeyPress(.return) { open(url); return .handled }
          .help(url.absoluteString).accessibilityLabel("打开提交 \(commit.id)")
      } else { Text(String(commit.id.prefix(7))).appFont(size: 14).monospaced().foregroundStyle(.tertiary) }
      if !commit.author.isEmpty {
        AsyncImage(url: commit.avatarURL.flatMap(URL.init(string:))) { phase in
          if case .success(let image) = phase { image.resizable().scaledToFill() }
          else { Text(String(commit.author.prefix(1)).uppercased()).appFont(size: 12).frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary) }
        }.frame(width: 20, height: 20).clipShape(Circle()).help(commit.author).accessibilityLabel(commit.author)
      }
      TaskPullRequestActivityDateView(value: commit.createdAt).frame(width: 36, alignment: .trailing)
    }.padding(.horizontal, 12).padding(.vertical, 10)
      .background(grouped ? Color.clear : Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).stroke(grouped ? Color.clear : Color.secondary.opacity(0.15)))
  }
}

struct TaskPullRequestActivityDateView: View {
  let value: String
  var body: some View {
    if let date = GitHubPRActivityDate.parse(value) {
      TimelineView(.periodic(from: .now, by: 60)) { context in
        let formatter = RelativeDateTimeFormatter()
        let _ = formatter.unitsStyle = .abbreviated
        Text(formatter.localizedString(for: date, relativeTo: context.date)).appFont(size: 14)
          .foregroundStyle(.tertiary).lineLimit(1).fixedSize(horizontal: true, vertical: false)
          .help(date.formatted(date: .abbreviated, time: .standard))
          .accessibilityLabel(date.formatted(date: .complete, time: .standard))
      }
    } else { Text(value).appFont(size: 14).foregroundStyle(.tertiary).lineLimit(1) }
  }
}
