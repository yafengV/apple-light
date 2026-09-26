import SwiftUI

struct TaskSourcesListView: View {
  let sources: [TaskSummarySource]
  let images: [ImageAttachment]
  let openFile: (FileAttachment) -> Void
  let openImage: (ImageAttachment, [ImageAttachment]) -> Void
  let openExternal: (URL) -> Void

  var body: some View {
    ForEach(sources) { source in
      switch source {
      case .file(let file):
        Button { openFile(file) } label: {
          Label(file.name, systemImage: file.isPDF ? "doc.richtext" : "doc.text")
            .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
        }
        .buttonStyle(.plain).help("预览文件：\(file.name)")
      case .image(let image):
        Button { openImage(image, images) } label: {
          Label(image.name, systemImage: "photo")
            .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
        }
        .buttonStyle(.plain).help("预览图片：\(image.name)")
      case .external(let source):
        if let url = try? BrowserAddress.url(source.url) {
          Button { openExternal(url) } label: {
            Label(source.title, systemImage: "link")
              .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
          }
          .buttonStyle(.plain).help(source.url)
        }
      case .tool(_, let name):
        Label(name, systemImage: "puzzlepiece.extension")
          .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
      case .webSearch:
        Label("网页搜索", systemImage: "globe")
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
}

struct TaskSourcesView: View {
  let sources: [TaskSummarySource]
  let dataRoot: URL
  let openExternal: (URL) -> Void
  let addFile: () -> Void
  let addImage: () -> Void
  let canAddFile: Bool
  let canAddImage: Bool
  @State private var query = ""
  @State private var previewFile: FileAttachment?
  @State private var previewImage: ImagePreviewItem?

  private var sourceImages: [ImageAttachment] {
    sources.compactMap { source in
      if case .image(let image) = source { return image }
      return nil
    }
  }

  private var filtered: [TaskSummarySource] {
    let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !term.isEmpty else { return sources }
    return sources.filter { $0.searchableText.localizedStandardContains(term) }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label("来源", systemImage: "square.stack").appFont(.headline)
        Text(sources.count.formatted()).appFont(.caption).foregroundStyle(.secondary)
        Spacer()
        Menu {
          Button("添加文件…", systemImage: "doc.badge.plus", action: addFile)
            .disabled(!canAddFile)
          Button("添加图片…", systemImage: "photo", action: addImage)
            .disabled(!canAddImage)
        } label: { Image(systemName: "plus") }
        .menuStyle(.borderlessButton)
        .help("添加来源")
        .accessibilityLabel("添加来源")
      }
      .padding(.horizontal, 20).padding(.vertical, 12)
      Divider()
      if !sources.isEmpty {
        TextField("搜索来源", text: $query)
          .textFieldStyle(.roundedBorder)
          .padding(.horizontal, 20).padding(.vertical, 12)
      }
      if filtered.isEmpty {
        ContentUnavailableView(query.isEmpty ? "暂无来源" : "没有匹配的来源",
          systemImage: "square.stack")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 14) {
            TaskSourcesListView(sources: filtered, images: sourceImages,
              openFile: { previewFile = $0 },
              openImage: { image, _ in previewImage = ImagePreviewItem(image) },
              openExternal: openExternal)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(20)
        }
      }
    }
    .sheet(item: $previewFile) { FileAttachmentPreview(file: $0, root: dataRoot) }
    .overlay {
      if let previewImage {
        ImageGalleryPreview(image: previewImage, images: sourceImages.map(ImagePreviewItem.init),
          root: dataRoot) { self.previewImage = nil }
      }
    }
  }
}
