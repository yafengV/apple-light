import AppKit
import SwiftUI

struct TaskPullRequestCommentMediaView: View {
  let media: GitHubPRCommentMedia
  let open: (URL) -> Void
  var openExternally: (URL) -> Void = { NSWorkspace.shared.open($0) }
  var load: @Sendable (GitHubPRCommentMedia) async throws -> GitHubPRCommentMediaLoader.Payload = { try await GitHubPRCommentMediaLoader.load($0) }
  @State private var presentation = PRCommentMediaPresentation()
  @State private var viewportHeight: CGFloat = 640 / 0.7
  @Environment(\.appAppearance) private var appearance

  var body: some View {
    Group {
      switch presentation.phase {
      case .loading:
        HStack(spacing: 8) { ProgressView().controlSize(.small).frame(width: 16, height: 16) }
          .padding(.horizontal, 16).padding(.vertical, 12).frame(minWidth: 160, minHeight: 96)
          .background(appearance.resolvedColors["buttonSecondaryBackgroundHover"].color, in: PRCommentMediaCornerShape(radius: 10))
          .accessibilityLabel("正在加载 GitHub 媒体")
      case .image(let image):
        PRCommentMediaImageLayout(intrinsic: image.size, viewportHeight: viewportHeight) {
          PRCommentMediaImageView(image: image, alt: media.alt, title: media.title)
        }
        .padding(.vertical, 12)
      case .unavailable:
        VStack(spacing: 8) {
          Text("预览不可用").font(Font(appearance.nativeFont(size: 13).withSize(13)))
            .foregroundStyle(appearance.resolvedColors["textForegroundTertiary"].color)
          PRCommentMediaOpenButton(available: { presentation.canOpen(media) }) {
            presentation.open(media, normally: open, externally: openExternally)
          }
        }
        .padding(.horizontal, 16).padding(.vertical, 12).frame(minWidth: 160, minHeight: 96)
        .background(appearance.resolvedColors["buttonSecondaryBackgroundHover"].color, in: PRCommentMediaCornerShape(radius: 12.5))
        .padding(.vertical, 12)
      }
    }
    .background { PRCommentMediaViewport { viewportHeight = $0 } }
    .task(id: media.url.absoluteString + (media.kind == .video ? "\u{0}video" : "\u{0}image")) {
      await presentation.load(media, using: load)
    }
    .onDisappear { presentation.cancel() }
  }
}

struct PRCommentMediaImageLayout: Layout {
  let intrinsic: CGSize
  let viewportHeight: CGFloat
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    PRCommentMediaImageMetrics.size(intrinsic: intrinsic, width: proposal.width, viewportHeight: viewportHeight)
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    subviews.first?.place(at: bounds.origin, proposal: .init(bounds.size))
  }
}

struct PRCommentMediaOpenButton: NSViewRepresentable {
  let available: () -> Bool
  let action: () -> Void
  @Environment(\.appAppearance) private var appearance
  @Environment(\.isEnabled) private var enabled
  func makeNSView(context: Context) -> AppearanceActionButton.Control { AppearanceActionButton.Control() }
  func updateNSView(_ view: AppearanceActionButton.Control, context: Context) {
    view.title = "在 GitHub 中打开"; view.setAccessibilityLabel(view.title)
    view.preferences = appearance; view.font = appearance.nativeFont(size: 13).withSize(13); view.outlinedPill = true
    view.canAct = { enabled && available() }; view.isEnabled = enabled && available(); view.activate = action
    view.invalidateIntrinsicContentSize(); view.needsDisplay = true
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: AppearanceActionButton.Control, context: Context) -> CGSize? {
    nsView.intrinsicContentSize
  }
  static func dismantleNSView(_ view: AppearanceActionButton.Control, coordinator: ()) {
    view.active = false; view.activate = nil; view.canAct = { false }
  }
}
