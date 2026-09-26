import AppKit
import SwiftUI

struct CodexTurnDiffView: View {
  let diff: CodexTurnDiff
  let root: URL
  @State private var expanded = false
  @State private var copied = false
  @State private var showingFullDiff = false
  @State private var fullDiff: String?
  @State private var loadError: String?

  var body: some View {
    DisclosureGroup(isExpanded: $expanded) {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          if diff.truncated {
            Text("下方显示前 262,144 个字符。")
              .foregroundStyle(.secondary)
          }
          Spacer()
          if diff.truncated {
            Button("查看完整差异") { openFullDiff() }.controlSize(.small)
          }
          Button(copied ? "已复制" : "复制完整差异") { copyFullDiff() }
            .controlSize(.small)
        }.appFont(.caption)
        if let loadError {
          Text(loadError).foregroundStyle(.red).appFont(.caption)
        }
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
    .sheet(isPresented: $showingFullDiff) {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text("本轮完整代码差异").font(.headline)
          Spacer()
          Button("完成") { showingFullDiff = false }
        }
        ScrollView {
          Text(fullDiff ?? "").appFont(.caption, design: .monospaced)
            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
      }.padding(20).frame(minWidth: 760, minHeight: 520)
    }
    .onChange(of: diff) { _, _ in
      copied = false
      fullDiff = nil
      loadError = nil
    }
  }

  private func openFullDiff() {
    do {
      fullDiff = try CodexTurnDiffStorage.load(diff, root: root)
      loadError = nil
      showingFullDiff = true
    } catch {
      loadError = error.localizedDescription
    }
  }

  private func copyFullDiff() {
    do {
      let source = try CodexTurnDiffStorage.load(diff, root: root)
      NSPasteboard.general.clearContents()
      guard NSPasteboard.general.setString(source, forType: .string) else {
        throw AgentFailure(message: "无法复制代码差异。")
      }
      copied = true
      loadError = nil
    } catch {
      loadError = error.localizedDescription
    }
  }
}
