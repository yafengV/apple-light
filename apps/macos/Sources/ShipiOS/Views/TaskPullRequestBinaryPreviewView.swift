import AppKit
import PDFKit
import SwiftUI

struct TaskPullRequestBinaryPreviewView: View {
  let preview: GitHubPRRichPreview.Binary

  var body: some View {
    HStack(alignment: .top, spacing: 1) {
      if let before = preview.before { pane(before, title: "之前") }
      if let after = preview.after { pane(after, title: "之后") }
      else if preview.before != nil { missingAfter }
    }
    .frame(maxWidth: .infinity)
    .background(.quaternary.opacity(0.2))
    .accessibilityIdentifier("pull-request-binary-preview")
  }

  private var missingAfter: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("之后").appFont(.caption).foregroundStyle(.secondary)
      Text("文件已删除").appFont(.caption).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 160)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.background)
  }

  @ViewBuilder private func pane(_ data: Data, title: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).appFont(.caption).foregroundStyle(.secondary)
      if preview.kind == .pdf {
        TaskPullRequestPDFPreview(data: data).frame(minHeight: 320, maxHeight: 500)
      } else if let image = NSImage(data: data) {
        Image(nsImage: image).resizable().scaledToFit()
          .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 500)
          .accessibilityLabel(title + "图片")
      } else { unavailable }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.background)
  }

  private var unavailable: some View {
    Text("预览不可用").appFont(.caption).foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, minHeight: 160)
  }
}

private struct TaskPullRequestPDFPreview: View {
  let data: Data
  @State private var document: PDFDocument?
  @State private var pageNumber = 1
  @State private var pageImage: NSImage?

  var body: some View {
    VStack(spacing: 8) {
      if let pageImage {
        Image(nsImage: pageImage).resizable().scaledToFit()
          .frame(maxWidth: .infinity, minHeight: 280, maxHeight: 460)
          .accessibilityLabel("PDF 第 \(pageNumber) 页")
      } else {
        Text("PDF 预览不可用").appFont(.caption).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 280)
      }
      if let document, document.pageCount > 1 {
        HStack(spacing: 12) {
          Button { pageNumber -= 1 } label: { Image(systemName: "chevron.left") }
            .disabled(pageNumber <= 1).accessibilityLabel("上一页")
          Text("\(pageNumber) / \(document.pageCount)").monospacedDigit()
            .appFont(.caption).accessibilityLabel("第 \(pageNumber) 页，共 \(document.pageCount) 页")
          Button { pageNumber += 1 } label: { Image(systemName: "chevron.right") }
            .disabled(pageNumber >= document.pageCount).accessibilityLabel("下一页")
        }.buttonStyle(.plain)
      }
    }
    .task(id: data) { load() }
    .onChange(of: pageNumber) { _, _ in renderPage() }
  }

  private func load() {
    document = PDFDocument(data: data)
    if document?.isLocked == true || document?.pageCount == 0 { document = nil }
    pageNumber = 1
    renderPage()
  }

  private func renderPage() {
    guard let page = document?.page(at: pageNumber - 1) else { pageImage = nil; return }
    pageImage = page.thumbnail(of: NSSize(width: 960, height: 1200), for: .mediaBox)
  }
}
