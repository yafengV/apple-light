import SwiftUI

struct TaskPullRequestThreadDiffView: View {
  let thread: GitHubPRReviewThread
  @Environment(\.appAppearance) private var appearance
  var body: some View {
    let diff = ReviewDiff(thread.diffHunk)
    ScrollView(.horizontal) {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(diff.lines) { line in
          HStack(spacing: 0) {
            Text(line.oldLine.map(String.init) ?? "").frame(width: 38, alignment: .trailing).foregroundStyle(.secondary)
            Text(line.newLine.map(String.init) ?? "").frame(width: 38, alignment: .trailing).foregroundStyle(.secondary)
            Text(line.displayText(markerStyle: appearance.diffMarkerStyle)).textSelection(.enabled)
              .padding(.horizontal, 12).foregroundStyle(line.kind == .header ? Color.secondary : Color.primary)
          }.appFont(size: 11, design: .monospaced).frame(maxWidth: .infinity, alignment: .leading)
            .background(background(line))
        }
      }.fixedSize(horizontal: true, vertical: false)
    }.padding(.vertical, 8).background(.quaternary.opacity(0.3))
      .overlay(alignment: .top) { Divider() }.overlay(alignment: .bottom) { Divider() }
  }
  private func background(_ line: ReviewDiffLine) -> Color {
    if let position = thread.hunkPosition {
      let number = position.side == .left ? line.oldLine : line.newLine
      if let number, number >= (position.startLine ?? position.line), number <= position.line {
        return appearance.accentColor.opacity(0.15)
      }
    }
    guard appearance.diffMarkerStyle == .color else { return .clear }
    switch line.kind { case .addition: return .green.opacity(0.1); case .deletion: return .red.opacity(0.1); default: return .clear }
  }
}
