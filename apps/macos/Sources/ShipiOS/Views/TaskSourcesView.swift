import SwiftUI

struct TaskSourcesListView: View {
  let sources: [TaskSummarySource]
  let images: [ImageAttachment]
  let openFile: (FileAttachment) -> Void
  let openImage: (ImageAttachment, [ImageAttachment]) -> Void
  let openExternal: (URL) -> Void
  let openSiteTool: (MCPToolExecution) -> Void

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
      case .siteTool(let execution):
        if let activity = execution.browserSiteTool {
          Button { openSiteTool(execution) } label: {
            HStack(spacing: 8) {
              Label(activity.name, systemImage: "puzzlepiece.extension")
              Spacer(minLength: 4)
              Text(activity.title.isEmpty ? activity.website : activity.title)
                .appFont(.caption).foregroundStyle(.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
          }
          .buttonStyle(.plain).help("查看 \(activity.website) 的站点工具调用")
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
  @State private var selectedSiteTool: MCPToolExecution?

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

  private var otherSources: [TaskSummarySource] {
    filtered.filter { if case .siteTool = $0 { return false }; return true }
  }

  private var siteToolWebsites: [(host: String, sources: [TaskSummarySource])] {
    var groups: [(host: String, sources: [TaskSummarySource])] = []
    for source in filtered {
      guard case .siteTool(let execution) = source, let host = execution.browserSiteTool?.website else { continue }
      if let index = groups.firstIndex(where: { $0.host == host }) {
        groups[index].sources.append(source)
      } else { groups.append((host, [source])) }
    }
    return groups
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
            TaskSourcesListView(sources: otherSources, images: sourceImages,
              openFile: { previewFile = $0 },
              openImage: { image, _ in previewImage = ImagePreviewItem(image) },
              openExternal: openExternal, openSiteTool: { selectedSiteTool = $0 })
            ForEach(siteToolWebsites, id: \.host) { group in
              VStack(alignment: .leading, spacing: 9) {
                Text(group.host).appFont(.caption, weight: .medium).foregroundStyle(.secondary)
                TaskSourcesListView(sources: group.sources, images: sourceImages,
                  openFile: { previewFile = $0 },
                  openImage: { image, _ in previewImage = ImagePreviewItem(image) },
                  openExternal: openExternal, openSiteTool: { selectedSiteTool = $0 })
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(20)
        }
      }
    }
    .sheet(item: $previewFile) { FileAttachmentPreview(file: $0, root: dataRoot) }
    .sheet(item: $selectedSiteTool) {
      BrowserSiteToolSourceDetail(execution: $0, openExternal: openExternal)
    }
    .overlay {
      if let previewImage {
        ImageGalleryPreview(image: previewImage, images: sourceImages.map(ImagePreviewItem.init),
          root: dataRoot) { self.previewImage = nil }
      }
    }
  }
}

private struct BrowserSiteToolSourceDetail: View {
  let execution: MCPToolExecution
  let openExternal: (URL) -> Void
  @Environment(\.dismiss) private var dismiss

  private var activity: BrowserSiteToolActivity? { execution.browserSiteTool }
  private var output: String {
    guard let raw = execution.output,
      let result = try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)) else {
      return execution.output ?? ""
    }
    return result["output"].text ?? ""
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text(activity?.name ?? "站点工具").appFont(.headline)
        Spacer()
        Button("关闭") { dismiss() }
      }
      if let activity {
        Text(activity.website).appFont(.caption).foregroundStyle(.secondary)
        if !activity.title.isEmpty { Text(activity.title) }
        Text(activity.url).appFont(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        if let url = try? BrowserAddress.url(activity.url) {
          Button("打开网站") { openExternal(url) }
        }
      }
      Divider()
      Text("调用结果").appFont(.caption, weight: .medium)
      ScrollView {
        Text(output.isEmpty ? "此调用没有文本结果。" : output)
          .appFont(.body).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(20).frame(width: 520, height: 380)
  }
}
