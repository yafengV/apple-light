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
            if let context = image.appshot {
              VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                  Button { open(image) } label: {
                    AppshotCardVisual(image: image, context: context, root: store.dataRoot)
                  }
                  .buttonStyle(.plain).focusable().focused($focusedImage, equals: image.id)
                  .accessibilityLabel("预览应用窗口：\(context.displayTitle)")
                  .onKeyPress(keys: [.space, .return], phases: .down) { press in
                    guard isEnabled, press.modifiers.isEmpty else { return .ignored }
                    open(image)
                    return .handled
                  }
                  if removable {
                    Button { remove(image) } label: { Image(systemName: "xmark.circle.fill") }
                      .buttonStyle(.plain).padding(6)
                      .help("移除截图").accessibilityLabel("移除截图：\(context.displayTitle)")
                  }
                }
                if !removable {
                  Text(context.displayTitle).lineLimit(1).truncationMode(.middle)
                    .appFont(size: 13).frame(width: 232)
                }
              }
            } else {
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
                    Button { remove(image) } label: { Image(systemName: "xmark.circle.fill") }
                      .buttonStyle(.plain).help("移除图片")
                      .accessibilityLabel("移除图片：\(image.name)")
                  }
                }.appFont(size: 10).frame(width: 112)
              }.padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
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
  private func remove(_ image: ImageAttachment) {
    if let onRemove { onRemove(image) } else { store.removeDraftImage(image) }
  }
}

private struct AppshotCardVisual: View {
  let image: ImageAttachment
  let context: AppshotContext
  let root: URL

  private var icon: NSImage? {
    if let stored = AppshotIcon.image(context.iconPNG) { return stored }
    guard let bundle = context.bundleIdentifier,
      let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
    return NSWorkspace.shared.icon(forFile: appURL.path)
  }

  var body: some View {
    ZStack(alignment: .bottom) {
      AttachmentThumbnail(image: image, root: root, size: 512)
        .frame(width: 232, height: 140, alignment: .bottom)
        .mask(LinearGradient(stops: [
          .init(color: .white, location: 0),
          .init(color: .white, location: 0.6),
          .init(color: .white.opacity(0.2), location: 0.8),
          .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom))
      Group {
        if let icon { Image(nsImage: icon).resizable().scaledToFit() }
        else { Image(systemName: "app").resizable().scaledToFit() }
      }.frame(width: 24, height: 24)
    }
    .frame(width: 232, height: 140)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    .clipShape(RoundedRectangle(cornerRadius: 16))
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
