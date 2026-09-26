import AppKit
import SwiftUI

struct TaskSummaryOutputPreview: View {
  let output: TaskSummaryOutputFile
  @Environment(\.dismiss) private var dismiss
  @State private var text: String?
  @State private var truncated = false
  @State private var error: String?

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(output.title).appFont(.headline)
          Text(output.name).appFont(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button("复制") {
          guard let text else { return }
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(text, forType: .string)
        }.disabled(text == nil)
        Button("在 Finder 中显示") {
          NSWorkspace.shared.activateFileViewerSelecting([output.url])
        }.disabled(!output.isAvailable)
        Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
      }.padding(16)
      Divider()
      if let text {
        ScrollView {
          Text(text.isEmpty ? "文件为空。" : text)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        if truncated {
          Text("仅显示前 1 MiB；完整文件可在 Finder 中打开。")
            .appFont(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
      } else if let error {
        ContentUnavailableView("无法读取输出", systemImage: "exclamationmark.triangle",
          description: Text(error))
        Button("重试") { Task { await load() } }.padding(.bottom, 16)
      } else {
        ProgressView("读取输出…").frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(minWidth: 640, minHeight: 400)
    .task(id: output.id) { await load() }
  }

  private func load() async {
    text = nil
    error = nil
    do {
      let result = try await Task.detached { try output.readLog() }.value
      text = result.text
      truncated = result.truncated
    } catch {
      self.error = error.localizedDescription
    }
  }
}
