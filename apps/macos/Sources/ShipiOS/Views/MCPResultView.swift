import AppKit
import SwiftUI

struct MCPResultView: View {
  let output: String
  @Environment(\.presentImageGallery) private var presentImageGallery
  @State private var document: MCPResultDocument?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let document {
        if document.isError {
          Label("工具返回错误", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        }
        ForEach(document.blocks) { block in
          VStack(alignment: .leading, spacing: 6) {
            content(block, images: document.previewImages)
            if let annotations = block.annotations {
              Text(annotations).appFont(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
          }
        }
        if let structured = document.structured {
          MCPResultTextBlock(title: "结构化结果", text: structured, monospaced: true)
        }
        if document.blocks.isEmpty && document.structured == nil {
          Text("工具未返回内容").foregroundStyle(.secondary)
        }
      } else { ProgressView().controlSize(.small) }
    }.task(id: output) {
      document = nil
      let raw = output
      let parsed = await Task.detached(priority: .userInitiated) { MCPResultDocument.parse(raw) }.value
      guard !Task.isCancelled else { return }
      document = parsed
    }
  }

  @ViewBuilder private func content(_ block: MCPResultDocument.Block, images: [ImagePreviewItem]) -> some View {
    switch block.content {
    case .text(let text): MCPResultTextBlock(title: "纯文本", text: text)
    case .unknown(let raw): MCPResultTextBlock(title: "工具内容", text: raw, monospaced: true)
    case .image(let data, let mime):
      MCPResultImageView(base64: data, mime: mime) { returnFocus in
        let selected = ImagePreviewItem(blockID: block.id, base64: data, mime: mime)
        presentImageGallery?(selected, images, returnFocus)
      }.disabled(presentImageGallery == nil)
    case .audio(let data, let mime): MCPResultAudioView(base64: data, mime: mime)
    case .resourceLink(let title, let uri, let description):
      VStack(alignment: .leading, spacing: 4) {
        Label("读取 \(title)", systemImage: "doc.text")
        Text(uri).foregroundStyle(.secondary).textSelection(.enabled)
        if let description { Text(description).textSelection(.enabled) }
      }.appFont(.callout)
    case .resource(let uri, let mime, let text, let blob):
      VStack(alignment: .leading, spacing: 6) {
        LabeledContent("URI") { Text(uri).textSelection(.enabled) }
        if let mime { LabeledContent("MIME 类型", value: mime) }
        if let text { MCPResultTextBlock(title: "资源内容", text: text, monospaced: true) }
        else if let blob { MCPResultTextBlock(title: "资源内容（Base64）", text: blob, monospaced: true) }
      }.appFont(.caption)
    }
  }
}

struct MCPResultTextBlock: View {
  let title: String
  let text: String
  var monospaced = false
  @State private var copied = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(title).foregroundStyle(.secondary)
        Spacer()
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(text, forType: .string)
          copied = true
        } label: {
          Image(systemName: copied ? "checkmark" : "doc.on.doc")
        }.buttonStyle(.plain).help(copied ? "已复制" : "复制内容")
          .accessibilityLabel(copied ? "已复制" : "复制\(title)")
      }.appFont(.caption).padding(8)
      Divider()
      ScrollView {
        Text(text).appFont(.callout, design: monospaced ? .monospaced : .default)
          .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
      }.frame(maxHeight: 192)
    }.background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.1)))
      .onChange(of: text) { _, _ in copied = false }
      .task(id: copied) {
        guard copied else { return }
        try? await Task.sleep(for: .seconds(2))
        if !Task.isCancelled { copied = false }
      }
  }
}
