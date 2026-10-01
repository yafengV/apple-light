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
                      .background {
                        if removable { AppshotHandoffAnchor(imageID: image.id, store: store) }
                      }
                      .opacity(removable && store.appshotHandoff?.imageID == image.id ? 0 : 1)
                  }
                  .buttonStyle(.plain).focusable().focused($focusedImage, equals: image.id)
                  .disabled(removable && store.appshotHandoff?.imageID == image.id)
                  .accessibilityLabel("预览应用窗口：\(context.displayTitle)")
                  .padding(.top, removable ? 0 : 10)
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
        }.padding(.horizontal, images.contains(where: { $0.appshot != nil }) ? 12 : 0)
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

enum AppshotCardLayout {
  static let width: CGFloat = 232
  static let height: CGFloat = 140

  static func screenshotHeight(pixelWidth: Int, pixelHeight: Int) -> CGFloat {
    guard pixelWidth > 0, pixelHeight > 0 else { return height }
    return CGFloat(pixelHeight) * min(width / CGFloat(pixelWidth), height / CGFloat(pixelHeight))
  }
}

struct AppshotCardVisual: View {
  let image: ImageAttachment
  let context: AppshotContext
  let root: URL
  @State private var thumbnail: CGImage?
  @State private var failed = false
  @State private var isHovered = false

  private var icon: NSImage? {
    if let stored = AppshotIcon.image(context.iconPNG) { return stored }
    guard let bundle = context.bundleIdentifier,
      let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
    return NSWorkspace.shared.icon(forFile: appURL.path)
  }

  var body: some View {
    ZStack(alignment: .bottom) {
      Color.clear.frame(width: AppshotCardLayout.width, height: AppshotCardLayout.height)
      if let thumbnail {
        Image(decorative: thumbnail, scale: 1)
          .resizable().scaledToFit()
          .frame(width: AppshotCardLayout.width,
            height: AppshotCardLayout.screenshotHeight(
              pixelWidth: thumbnail.width, pixelHeight: thumbnail.height))
          .padding(.horizontal, 12)
          .mask(LinearGradient(stops: [
            .init(color: .white, location: 0),
            .init(color: .white.opacity(0.21), location: 0.79),
            .init(color: .clear, location: 1),
          ], startPoint: .top, endPoint: .bottom))
          .shadow(color: .black.opacity(0.3), radius: 5, x: 0, y: 10)
      } else if failed {
        Image(systemName: "exclamationmark.triangle")
          .frame(width: AppshotCardLayout.width, height: AppshotCardLayout.height)
          .accessibilityLabel("截图不可用")
      } else {
        ProgressView().controlSize(.small)
          .frame(width: AppshotCardLayout.width, height: AppshotCardLayout.height)
      }
      if let icon {
        Image(nsImage: icon).resizable().scaledToFit()
          .frame(width: 24, height: 24)
          .accessibilityHidden(true)
      }
    }
    .frame(width: AppshotCardLayout.width, height: AppshotCardLayout.height)
    .background(isHovered ? Color(nsColor: .controlBackgroundColor).opacity(0.75) : .clear,
      in: RoundedRectangle(cornerRadius: 16))
    .contentShape(RoundedRectangle(cornerRadius: 16))
    .onHover { isHovered = $0 }
    .task(id: image.id) {
      thumbnail = nil
      failed = false
      do {
        let decoded = try await Task.detached(priority: .userInitiated) {
          try ImageAttachmentStorage.thumbnail(image, root: root, size: 512)
        }.value
        guard !Task.isCancelled else { return }
        thumbnail = decoded
      } catch { if !Task.isCancelled { failed = true } }
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
