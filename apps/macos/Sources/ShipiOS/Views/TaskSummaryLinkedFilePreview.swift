import AppKit
import QuickLookUI
import SwiftUI

/// In-app fallback for task output files without a mounted workspace file pane.
struct TaskSummaryLinkedFilePreview: View {
  let file: TaskSummaryLinkedFile
  @Environment(\.dismiss) private var dismiss
  @State private var revision = 0

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text(file.title).appFont(.headline).lineLimit(1)
          Text(file.path).appFont(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer()
        Button("在 Finder 中显示") {
          NSWorkspace.shared.activateFileViewerSelecting([file.url])
        }.disabled(!available)
        Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
      }.padding(16)
      Divider()
      if available {
        TaskSummaryQuickLookView(url: file.url)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ContentUnavailableView("输出文件不可用", systemImage: "doc.questionmark",
          description: Text("文件可能已移除或不再位于任务工作区内。"))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        Button("重试") { revision += 1 }.padding(.bottom, 16)
      }
    }
    .frame(minWidth: 720, minHeight: 500)
  }

  private var available: Bool {
    _ = revision
    return file.previewPath(in: file.root) != nil
  }
}

private struct TaskSummaryQuickLookView: NSViewRepresentable {
  let url: URL

  func makeNSView(context: Context) -> QLPreviewView {
    let view = QLPreviewView(frame: .zero, style: .normal)
    view?.previewItem = url as NSURL
    return view!
  }

  func updateNSView(_ view: QLPreviewView, context: Context) {
    view.previewItem = url as NSURL
  }
}
