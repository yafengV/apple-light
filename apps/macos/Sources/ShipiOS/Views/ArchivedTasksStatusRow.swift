import SwiftUI

struct ArchivedTasksStatusRow: View {
  enum Kind: String {
    case loading, failed, empty, noMatches
    var title: String {
      switch self {
      case .loading: "正在加载已归档任务…"
      case .failed: "无法加载已归档任务"
      case .empty: "暂无已归档任务"
      case .noMatches: "没有匹配的归档任务"
      }
    }
  }
  let kind: Kind

  var body: some View {
    HStack(spacing: 8) {
      if kind == .loading { ProgressView().controlSize(.small).accessibilityHidden(true) }
      Text(kind.title).appFont(size: 13)
        .multilineTextAlignment(kind == .loading ? .leading : .center)
    }
    .foregroundStyle(.secondary)
    .padding(.horizontal, 16)
    .frame(maxWidth: .infinity, minHeight: 64, alignment: kind == .loading ? .leading : .center)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("archived-tasks-status-\(kind.rawValue)")
  }
}
