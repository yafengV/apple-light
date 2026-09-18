import AppKit
import SwiftUI

struct ImageAttachmentsView: View {
  let store: WorkspaceStore
  let images: [ImageAttachment]
  var removable = false
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.presentImageGallery) private var presentImageGallery
  @FocusState private var focusedImage: UUID?
  var onRemove: ((ImageAttachment) -> Void)?
  var body: some View {
    if !images.isEmpty {
      ScrollView(.horizontal) {
        HStack(spacing: 10) {
          ForEach(images) { image in
            VStack(spacing: 4) {
              Button {
                open(image)
              } label: {
                AttachmentThumbnail(image: image, root: store.dataRoot, size: 120)
                  .frame(width: 112, height: 70).clipped()
              }.buttonStyle(.plain).focusable().focused($focusedImage, equals: image.id)
                .accessibilityLabel("预览图片：\(image.name)")
                .onKeyPress(keys: [.space, .return], phases: .down) { press in
                  guard isEnabled, press.modifiers.isEmpty else { return .ignored }
                  open(image)
                  return .handled
                }
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
  private func open(_ image: ImageAttachment) {
    guard isEnabled else { return }
    focusedImage = nil
    if let presentImageGallery {
      presentImageGallery(ImagePreviewItem(image), images.map(ImagePreviewItem.init), { focusedImage = image.id })
    } else { store.preview(image, images: images) }
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
