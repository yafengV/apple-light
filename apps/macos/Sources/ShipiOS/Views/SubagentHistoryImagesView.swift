import SwiftUI

/// Native history retains the submitted local paths. Read only this workspace's
/// own immutable attachment files; a model-supplied arbitrary path is not opened.
struct SubagentHistoryImagesView: View {
  let store: WorkspaceStore
  let paths: [String]
  @State private var images: [ImageAttachment] = []
  @State private var unavailable = false
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ImageAttachmentsView(store: store, images: images)
      if unavailable { Label("部分图片不可用", systemImage: "exclamationmark.triangle").appFont(.caption).foregroundStyle(.secondary) }
    }.task(id: paths) {
      let root = store.dataRoot
      let result = await Task.detached(priority: .userInitiated) {
        paths.prefix(ImageAttachmentStorage.maxCount).map { try? ImageAttachmentStorage.storedImage(path: $0, root: root) }
      }.value
      guard !Task.isCancelled else { return }
      images = result.compactMap { $0 }; unavailable = images.count != paths.count
    }
  }
}
