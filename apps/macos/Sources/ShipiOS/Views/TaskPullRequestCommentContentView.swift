import AVKit
import SwiftUI

struct TaskPullRequestCommentContentView: View {
  let comment: GitHubPRComment
  let state: GitHubPRDiscussionState
  let enabled: Bool
  let writable: Bool
  let mentionRequest: GitHubPRMentionRequest?
  let open: (URL) -> Void
  let submit: (GitHubPRDiscussionAction, String?) -> Void
  @State private var expanded = false
  @State private var contentHeight: CGFloat = 0
  private let collapsedHeight: CGFloat = 60
  private var draft: GitHubPRCommentDraft? { state.drafts[comment.id] }
  private var commentBody: String { comment.body.trimmingCharacters(in: .whitespacesAndNewlines) }
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let draft, case .edit = draft.target { composer(draft, label: "保存更改") }
      else {
        commentContent
          .fixedSize(horizontal: false, vertical: true)
          .background {
            GeometryReader { proxy in
              Color.clear.preference(key: PullRequestCommentContentHeight.self,
                value: proxy.size.height)
            }
          }
          .frame(height: contentHeight > collapsedHeight + 1 && !expanded ? collapsedHeight : nil,
            alignment: .top)
          .clipped()
        if contentHeight > collapsedHeight + 1 {
          Button {
            expanded.toggle()
          } label: {
            HStack(spacing: 5) {
              Text(expanded ? "收起" : "展开更多")
              Image(systemName: "chevron.down").rotationEffect(.degrees(expanded ? 180 : 0))
            }.appFont(.caption).foregroundStyle(.secondary)
          }.buttonStyle(.plain)
            .accessibilityLabel(expanded ? "收起评论" : "展开完整评论")
            .accessibilityValue(expanded ? "已展开" : "已收起")
        }
      }
      if let draft, case .reply = draft.target { composer(draft, label: "发布回复") }
    }
    .onPreferenceChange(PullRequestCommentContentHeight.self) { contentHeight = $0 }
    .onChange(of: comment.body) { _, _ in expanded = false }
  }
  @ViewBuilder private var commentContent: some View {
    let segments = GitHubPRCommentSegment.parse(commentBody)
    if segments.count == 1, case .markdown = segments[0] {
      MessageMarkdownView(source: commentBody, partPrefix: "pr-comment-" + comment.id,
        openLink: open)
    } else {
      VStack(alignment: .leading, spacing: 14) {
        ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
          switch segment {
          case .markdown(let source):
            MessageMarkdownView(source: source,
              partPrefix: "pr-comment-\(comment.id)-\(index)", openLink: open)
          case .media(let media):
            TaskPullRequestCommentMediaView(media: media, open: open)
          }
        }
      }
    }
  }
  private func composer(_ draft: GitHubPRCommentDraft, label: String) -> some View {
    TaskPullRequestCommentComposer(text: Binding(get: { state.drafts[comment.id]?.text ?? "" }, set: {
      state.drafts[comment.id]?.text = $0; state.clearError(.draft(comment.id))
    }), label: label, focus: draft.focus, enabled: enabled, busy: state.pendingOwner == .draft(comment.id),
      cancel: { state.cancelDraft(comment.id) }, inputEnabled: state.canEdit(.draft(comment.id), writable: writable),
      error: state.message(for: .draft(comment.id)), mentionRequest: mentionRequest) {
        if let action = state.draftAction(comment.id) { submit(action, comment.id) }
      }
  }
}

private struct TaskPullRequestCommentMediaView: View {
  let media: GitHubPRCommentMedia
  let open: (URL) -> Void
  @State private var image: NSImage?
  @State private var videoPlayer: AVPlayer?
  @State private var temporaryFolder: URL?
  @State private var failed = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let image {
        Image(nsImage: image).resizable().scaledToFit()
          .frame(maxWidth: 640, maxHeight: 500)
          .clipShape(RoundedRectangle(cornerRadius: 8))
          .accessibilityLabel(media.alt.isEmpty ? "GitHub 图片" : media.alt)
      } else if let videoPlayer {
        VideoPlayer(player: videoPlayer)
          .aspectRatio(16 / 9, contentMode: .fit)
          .frame(maxWidth: 640)
          .clipShape(RoundedRectangle(cornerRadius: 8))
          .accessibilityLabel(media.alt.isEmpty ? "GitHub 视频" : media.alt)
      } else if failed {
        Text("预览不可用").foregroundStyle(.secondary)
      } else {
        HStack(spacing: 7) {
          ProgressView().controlSize(.small)
          Text("正在加载 GitHub 媒体…").foregroundStyle(.secondary)
        }
      }
      Button("在 GitHub 中打开") { open(media.url) }
        .buttonStyle(.link).appFont(.caption)
    }
    .task(id: media.url) { await load() }
    .onDisappear { cleanup() }
  }

  private func load() async {
    failed = false
    do {
      let data = try await GitHubPRCommentMediaLoader.load(media)
      try Task.checkCancellation()
      if media.kind == .image {
        guard let decoded = NSImage(data: data) else {
          throw AgentFailure(message: "无法解码 GitHub 图片。")
        }
        image = decoded
      } else {
        let folder = FileManager.default.temporaryDirectory
          .appendingPathComponent("shipios-pr-media-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700])
        do {
          let file = folder.appendingPathComponent("preview." + videoExtension)
          try data.write(to: file, options: .atomic)
          try Task.checkCancellation()
          temporaryFolder = folder
          videoPlayer = AVPlayer(url: file)
        } catch {
          try? FileManager.default.removeItem(at: folder)
          throw error
        }
      }
    } catch is CancellationError {
      return
    } catch {
      failed = true
    }
  }

  private var videoExtension: String {
    let pathExtension = media.url.pathExtension.lowercased()
    return ["mov", "mp4", "webm"].contains(pathExtension) ? pathExtension : "mp4"
  }

  private func cleanup() {
    videoPlayer?.pause()
    videoPlayer = nil
    image = nil
    if let temporaryFolder { try? FileManager.default.removeItem(at: temporaryFolder) }
    temporaryFolder = nil
  }
}

private struct PullRequestCommentContentHeight: PreferenceKey {
  static var defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct TaskPullRequestCommentAvatar: View {
  let comment: GitHubPRComment
  var body: some View {
    AsyncImage(url: comment.avatarURL.flatMap(URL.init(string:))) { phase in
      if case .success(let image) = phase { image.resizable().scaledToFill() }
      else { Text(String(comment.author.prefix(1)).uppercased()).appFont(size: 12, weight: .semibold)
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary) }
    }.frame(width: 24, height: 24).clipShape(Circle()).accessibilityHidden(true)
  }
}
