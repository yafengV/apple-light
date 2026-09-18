import AppKit
import SwiftUI

struct ImageAttachmentsView: View {
  let store: WorkspaceStore
  let images: [ImageAttachment]
  var removable = false
  var onPreview: ((ImageAttachment) -> Void)?
  var onRemove: ((ImageAttachment) -> Void)?
  var body: some View {
    if !images.isEmpty {
      ScrollView(.horizontal) {
        HStack(spacing: 10) {
          ForEach(images) { image in
            VStack(spacing: 4) {
              Button {
                if let onPreview { onPreview(image) } else { store.preview(image) }
              } label: {
                AttachmentThumbnail(image: image, root: store.dataRoot, size: 120)
                  .frame(width: 112, height: 70).clipped()
              }.buttonStyle(.plain).accessibilityLabel("预览图片：\(image.name)")
              HStack(spacing: 4) {
                Text(image.name).lineLimit(1).truncationMode(.middle)
                if removable {
                  Button {
                    if let onRemove { onRemove(image) } else { store.removeDraftImage(image) }
                  } label: {
                    Image(systemName: "xmark.circle.fill")
                  }
                  .buttonStyle(.plain).help("移除图片").accessibilityLabel("移除图片：\(image.name)")
                }
              }.appFont(size: 10).frame(width: 112)
            }.padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
          }
        }
      }.scrollIndicators(.hidden).accessibilityLabel("图片附件")
    }
  }
}

struct AttachmentThumbnail: View {
  let image: ImageAttachment
  let root: URL
  let size: Int
  @State private var thumbnail: NSImage?
  @State private var error: String?
  var body: some View {
    Group {
      if let thumbnail {
        Image(nsImage: thumbnail).resizable().scaledToFit()
      } else if let error {
        Label(error, systemImage: "exclamationmark.triangle").appFont(.caption)
      } else {
        ProgressView().controlSize(.small)
      }
    }.task(id: image.id) {
      thumbnail = nil
      error = nil
      do {
        let cgImage = try await Task.detached(priority: .userInitiated) {
          try ImageAttachmentStorage.thumbnail(image, root: root, size: size)
        }.value
        guard !Task.isCancelled else { return }
        thumbnail = NSImage(cgImage: cgImage, size: .zero)
      } catch { if !Task.isCancelled { self.error = "图片不可用" } }
    }
  }
}

struct ImageAttachmentPreview: View {
  let image: ImageAttachment
  let root: URL
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    VStack(spacing: 16) {
      HStack {
        Text(image.name).appFont(.headline).lineLimit(1).truncationMode(.middle)
        Spacer()
        Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      AttachmentThumbnail(image: image, root: root, size: 1600)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      Text(ByteCountFormatter.string(fromByteCount: Int64(image.byteCount), countStyle: .file))
        .appFont(.caption).foregroundStyle(.secondary)
    }.padding(20).frame(width: 680, height: 480)
  }
}
