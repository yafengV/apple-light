import SwiftUI

struct CodexNoticeView: View {
  let kind: CodexNoticeKind
  let message: String

  private var title: String {
    switch kind {
    case .warning: "Codex 警告"
    case .deprecation: "功能弃用提示"
    case .modelChange: "模型已切换"
    }
  }
  private var symbol: String {
    kind == .modelChange ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(title, systemImage: symbol).appFont(.caption, weight: .semibold)
      Text(message).appFont(.callout).textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .foregroundStyle(kind == .modelChange ? Color.secondary : Color.orange)
    .padding(12)
    .background(kind == .modelChange ? Color.primary.opacity(0.025) : Color.orange.opacity(0.06),
      in: RoundedRectangle(cornerRadius: 9))
    .accessibilityElement(children: .combine)
  }
}
