import SwiftUI

struct FileAttachmentsView: View {
  let store: WorkspaceStore
  let files: [FileAttachment]
  var removable = false
  var onPreview: ((FileAttachment) -> Void)?
  var onRemove: ((FileAttachment) -> Void)?
  var body: some View {
    if !files.isEmpty {
      ScrollView(.horizontal) {
        HStack(spacing: 8) {
          ForEach(files) { file in
            HStack(spacing: 8) {
              Button {
                if let onPreview { onPreview(file) } else { store.preview(file) }
              } label: {
                Label {
                  VStack(alignment: .leading, spacing: 3) {
                    Text(file.name).lineLimit(1).truncationMode(.middle)
                    Text(file.isPDF ? "PDF · 文字内容" : ByteCountFormatter.string(fromByteCount: Int64(file.byteCount), countStyle: .file))
                      .foregroundStyle(.secondary).appFont(size: 10)
                  }.frame(maxWidth: 170, alignment: .leading)
                } icon: { Image(systemName: file.isPDF ? "doc.richtext" : "doc.text") }
              }.buttonStyle(.plain).accessibilityLabel("预览文件：\(file.name)")
              if removable {
                Button {
                  if let onRemove { onRemove(file) } else { store.removeDraftFile(file) }
                } label: { Image(systemName: "xmark.circle.fill") }
                  .buttonStyle(.plain).accessibilityLabel("移除文件：\(file.name)")
              }
            }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
          }
        }
      }.scrollIndicators(.hidden).appFont(.caption).accessibilityLabel("文件附件")
    }
  }
}

struct FileAttachmentPreview: View {
  let file: FileAttachment
  let root: URL
  @Environment(\.dismiss) private var dismiss
  @State private var content: String?
  @State private var error: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text(file.name).appFont(.headline).lineLimit(1).truncationMode(.middle)
        Spacer()
        Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      if let error { ContentUnavailableView(error, systemImage: "exclamationmark.triangle") }
      else if let content {
        ScrollView { Text(content.isEmpty ? "空文件" : content).textSelection(.enabled)
          .font(.system(size: 12, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading) }
      } else { ProgressView("正在读取文件…").frame(maxWidth: .infinity, maxHeight: .infinity) }
      Text(file.isPDF ? "发送时包含以上提取的文字，不包含 PDF 页面图像。" : "发送时包含以上文件内容。")
        .appFont(.caption).foregroundStyle(.secondary)
    }.padding(20).frame(width: 680, height: 480)
      .task(id: file.id) {
        do {
          let text = try await Task.detached(priority: .userInitiated) { try FileAttachmentStorage.text(file, root: root) }.value
          if !Task.isCancelled { content = text }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
      }
  }
}
