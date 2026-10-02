import AppKit
import PDFKit
import SwiftUI

struct TaskPullRequestBinaryPreviewView: View {
  let preview: GitHubPRRichPreview.Binary

  var body: some View {
    HStack(alignment: .top, spacing: 1) {
      if preview.before != nil || preview.after == nil { pane(preview.before, side: "之前") }
      pane(preview.after, side: "之后")
    }
    .frame(maxWidth: .infinity)
    .background(.quaternary.opacity(0.2))
    .accessibilityIdentifier("pull-request-binary-preview")
  }

  @ViewBuilder private func pane(_ data: Data?, side: String) -> some View {
    Group {
      if preview.kind == .pdf {
        if let data { TaskPullRequestPDFPreview(data: data) }
        else { placeholder("无 PDF 预览") }
      } else if let data, let image = NSImage(data: data) {
        Image(nsImage: image).resizable().scaledToFit()
          .frame(maxWidth: .infinity, minHeight: 136, maxHeight: 500)
          .padding(preview.kind == .svg ? 12 : 0)
          .background(preview.kind == .svg ? Color.white : Color.clear)
          .clipShape(RoundedRectangle(cornerRadius: 3))
          .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
          .accessibilityLabel(side + "图片预览")
      } else { placeholder("无图片") }
    }
    .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
    .padding(12)
    .background(.background)
  }

  private func placeholder(_ text: String) -> some View {
    Text(text).appFont(.caption).foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, minHeight: 160)
  }
}

private struct TaskPullRequestPDFPreview: View {
  private enum PagerControl: Hashable { case previous, next }

  let data: Data
  @State private var document: PDFDocument?
  @State private var pageNumber = 1
  @State private var pageImage: NSImage?
  @State private var hovered = false
  @FocusState private var focusedControl: PagerControl?

  var body: some View {
    Group {
      if let pageImage {
        Image(nsImage: pageImage).resizable().scaledToFit()
          .frame(maxWidth: .infinity)
          .clipShape(RoundedRectangle(cornerRadius: 3))
          .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
          .accessibilityLabel("PDF 第 \(pageNumber) 页")
      } else {
        Text("无法渲染 PDF 预览").appFont(.caption).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 160)
      }
    }
    .overlay(alignment: .topTrailing) {
      if let document, document.pageCount > 1 {
        HStack(spacing: 2) {
          Button { pageNumber -= 1 } label: { Image(systemName: "chevron.left") }
            .disabled(pageNumber <= 1).accessibilityLabel("上一页")
            .focused($focusedControl, equals: .previous)
          Text("\(pageNumber)/\(document.pageCount)").monospacedDigit()
            .appFont(.caption).foregroundStyle(.secondary)
            .accessibilityLabel("第 \(pageNumber) 页，共 \(document.pageCount) 页")
          Button { pageNumber += 1 } label: { Image(systemName: "chevron.right") }
            .disabled(pageNumber >= document.pageCount).accessibilityLabel("下一页")
            .focused($focusedControl, equals: .next)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        .opacity(hovered || focusedControl != nil ? 1 : 0)
        .allowsHitTesting(hovered || focusedControl != nil)
        .padding(4)
      }
    }
    .onHover { hovered = $0 }
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
