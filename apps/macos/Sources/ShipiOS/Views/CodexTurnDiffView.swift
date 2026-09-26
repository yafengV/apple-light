import AppKit
import SwiftUI

struct CodexTurnDiffView: View {
  let diff: CodexTurnDiff
  @State private var expanded = false
  @State private var copied = false

  var body: some View {
    DisclosureGroup(isExpanded: $expanded) {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          if diff.truncated {
            Text("差异内容过长，仅显示前 262,144 个字符。")
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button(copied ? "已复制" : "复制显示内容") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(diff.unifiedDiff, forType: .string)
            copied = true
          }.controlSize(.small)
        }.appFont(.caption)
        ScrollView {
          Text(diff.unifiedDiff).appFont(.caption, design: .monospaced)
            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxHeight: 320)
      }.padding(.top, 8)
    } label: {
      Label(diff.changedFileCount > 0 ? "本轮代码变更 · \(diff.changedFileCount) 个文件" : "本轮代码变更",
        systemImage: "curlybraces.square")
        .appFont(.caption)
    }
    .padding(12)
    .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.primary.opacity(0.06)))
    .onChange(of: diff.unifiedDiff) { _, _ in copied = false }
  }
}
