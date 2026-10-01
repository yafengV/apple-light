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
    filtered.filter {
      if case .siteTool = $0 { return false }
      if case .webSearch = $0 { return false }
      return true
    }
  }

  private var webSearchSource: CodexWebSearchSummary? {
    for source in filtered {
      if case .webSearch(let summary) = source { return summary }
    }
    return nil
  }

  private var siteToolWebsites: [SiteToolWebsiteGroup] {
    var groups: [SiteToolWebsiteGroup] = []
    for source in filtered {
      guard case .siteTool(let execution) = source, let host = execution.browserSiteTool?.website else { continue }
      if let index = groups.firstIndex(where: { $0.host == host }) {
        groups[index].calls.append(execution)
      } else { groups.append(SiteToolWebsiteGroup(host: host, calls: [execution])) }
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
              openExternal: openExternal, openSiteTool: { _ in })
            ForEach(siteToolWebsites) { group in
              BrowserSiteToolWebsiteSection(group: group, openExternal: openExternal)
            }
            if let webSearchSource {
              CodexWebSearchSourceSection(summary: webSearchSource, openExternal: openExternal)
            }
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

private struct CodexWebSearchSourceSection: View {
  let summary: CodexWebSearchSummary
  let openExternal: (URL) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      Label("网页搜索", systemImage: "globe").appFont(.body, weight: .medium)
      if summary.queryCount > 0 {
        DisclosureGroup("搜索 \(summary.queryCount) 次") {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(summary.queries, id: \.self) { query in
              Text(query).appFont(.body).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }.padding(.top, 6)
        }
      }
      if !summary.viewedLinks.isEmpty {
        DisclosureGroup("打开 \(summary.viewedLinks.count) 个网页") {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(summary.viewedLinks) { link in
              if let url = try? BrowserAddress.url(link.url) {
                Button { openExternal(url) } label: {
                  Label(link.title, systemImage: "link").lineLimit(1)
                }
                .buttonStyle(.plain).help(link.url)
              }
            }
          }.padding(.top, 6)
        }
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
  }
}

private struct SiteToolWebsiteGroup: Identifiable {
  let host: String
  var calls: [MCPToolExecution]
  var id: String { host }

  var tools: [SiteToolNameGroup] {
    var groups: [SiteToolNameGroup] = []
    for call in calls {
      guard let name = call.browserSiteTool?.name else { continue }
      if let index = groups.firstIndex(where: { $0.name == name }) {
        groups[index].calls.append(call)
      } else { groups.append(SiteToolNameGroup(name: name, calls: [call])) }
    }
    return groups
  }
}

private struct SiteToolNameGroup: Identifiable {
  let name: String
  var calls: [MCPToolExecution]
  var id: String { name }
}

private struct BrowserSiteToolWebsiteSection: View {
  let group: SiteToolWebsiteGroup
  let openExternal: (URL) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      if let raw = group.calls.first?.browserSiteTool?.url,
        let url = try? BrowserAddress.url(raw) {
        Button { openExternal(url) } label: {
          Label(group.host, systemImage: "globe")
            .appFont(.body, weight: .medium)
        }.buttonStyle(.plain).help(raw)
      } else {
        Label(group.host, systemImage: "globe").appFont(.body, weight: .medium)
      }
      ForEach(group.tools) { tool in
        DisclosureGroup {
          VStack(alignment: .leading, spacing: 12) {
            ForEach(tool.calls) { call in
              BrowserSiteToolCallDetails(execution: call)
            }
          }.padding(.top, 6)
        } label: {
          HStack {
            Text(tool.name).lineLimit(1)
            Spacer()
            Text("\(tool.calls.count) 次")
              .appFont(.caption).foregroundStyle(.secondary)
          }
        }
        .accessibilityLabel("\(group.host) 的 \(tool.name)，使用 \(tool.calls.count) 次")
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
  }
}

private struct BrowserSiteToolCallDetails: View {
  let execution: MCPToolExecution

  private var legacyOutput: String? {
    guard let raw = execution.output,
      let result = try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)) else {
      return execution.output
    }
    return result["output"].text
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let input = execution.siteToolInputJSON {
        codeBlock(title: execution.siteToolInputTruncated == true ? "输入（已截断）" : "输入", content: input)
      }
      if let output = execution.siteToolOutputJSON ?? legacyOutput {
        codeBlock(title: execution.siteToolOutputTruncated == true ? "结果（已截断）" : "结果", content: output)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.leading, 12)
  }

  private func codeBlock(title: String, content: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).appFont(.caption, weight: .medium).foregroundStyle(.secondary)
      ScrollView {
        Text(content)
          .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 192)
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
  }
}
