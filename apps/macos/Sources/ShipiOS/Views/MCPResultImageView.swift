import AppKit
import SwiftUI

struct MCPResultImageView: View {
  let base64: String
  let mime: String
  @State private var image: NSImage?
  @State private var error: String?
  @State private var showingPreview = false

  var body: some View {
    Group {
      if let image {
        Button { showingPreview = true } label: {
          Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 192)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).accessibilityLabel("预览工具返回的图片")
      } else if let error {
        Label(error, systemImage: "photo.badge.exclamationmark").foregroundStyle(.secondary)
      } else { ProgressView().controlSize(.small) }
    }.task(id: base64 + mime) {
      image = nil; error = nil
      do {
        let source = base64, type = mime
        let result = try await Task.detached(priority: .userInitiated) {
          try MCPResultMedia.thumbnail(base64: source, mime: type, size: 640)
        }.value
        guard !Task.isCancelled else { return }
        image = NSImage(cgImage: result, size: .zero)
      } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    .sheet(isPresented: $showingPreview) { MCPResultImagePreview(base64: base64, mime: mime) }
  }
}

private struct MCPResultImagePreview: View {
  let base64: String
  let mime: String
  @Environment(\.dismiss) private var dismiss
  @State private var image: NSImage?
  @State private var error: String?
  @State private var zoom = 1.0

  var body: some View {
    VStack(spacing: 12) {
      HStack {
        Text("工具返回的图片").appFont(.headline)
        Spacer()
        Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      GeometryReader { geometry in
        if let image {
          let fit = min(geometry.size.width / max(1, image.size.width), geometry.size.height / max(1, image.size.height))
          ScrollView([.horizontal, .vertical]) {
            Image(nsImage: image).resizable().interpolation(.high)
              .frame(width: image.size.width * fit * zoom, height: image.size.height * fit * zoom)
              .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
          }
        } else if let error {
          Text(error).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
      }
      HStack {
        Button { zoom = max(0.25, zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
          .accessibilityLabel("缩小图片").keyboardShortcut("-", modifiers: .command)
        Slider(value: $zoom, in: 0.25...4).frame(width: 160).accessibilityLabel("图片缩放")
        Button { zoom = min(4, zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
          .accessibilityLabel("放大图片").keyboardShortcut("+", modifiers: .command)
        Text("\(Int(zoom * 100))%").monospacedDigit().frame(width: 48)
        Spacer()
        Button("适应窗口") { zoom = 1 }.keyboardShortcut("0", modifiers: .command)
      }.disabled(image == nil)
    }.padding(20).frame(width: 720, height: 540)
      .task {
        do {
          let source = base64, type = mime
          let result = try await Task.detached(priority: .userInitiated) {
            try MCPResultMedia.thumbnail(base64: source, mime: type, size: 4096)
          }.value
          guard !Task.isCancelled else { return }
          image = NSImage(cgImage: result, size: .zero)
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
      }
  }
}
