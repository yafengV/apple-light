import AppKit
import SwiftUI

/// Searchable output list shown in the same summary panel.
struct TaskSummaryOutputsView: View {
  let artifacts: [TaskSummaryArtifact]
  let linkedFiles: [TaskSummaryLinkedFile]
  let previewLog: (TaskSummaryOutputFile) -> Void
  let openFile: (TaskSummaryLinkedFile) -> Void
  let refresh: () -> Void
  let back: () -> Void
  let close: () -> Void
  @State private var query = ""

  private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var matchingFiles: [TaskSummaryLinkedFile] {
    guard !term.isEmpty else { return linkedFiles }
    return linkedFiles.filter { $0.searchableText.localizedStandardContains(term) }
  }
  private var matchingArtifacts: [TaskSummaryArtifact] {
    guard !term.isEmpty else { return artifacts }
    return artifacts.filter { artifact in
      artifact.title.localizedStandardContains(term)
        || artifact.outputs.contains { $0.name.localizedStandardContains(term)
          || $0.title.localizedStandardContains(term) }
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Button(action: back) { Image(systemName: "chevron.left") }
          .buttonStyle(.plain).help("返回摘要")
          .accessibilityLabel("返回摘要")
        Label("输出", systemImage: "shippingbox").appFont(.headline)
        Spacer()
        Button(action: refresh) { Image(systemName: "arrow.clockwise") }
          .buttonStyle(.plain).help("刷新输出")
          .accessibilityLabel("刷新输出")
        Button(action: close) { Image(systemName: "xmark") }
          .buttonStyle(.plain).help("关闭摘要")
          .accessibilityLabel("关闭摘要")
      }.padding(.horizontal, 16).padding(.vertical, 13)
      Divider()
      TextField("搜索输出", text: $query)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("搜索输出")
        .padding(12)
      if matchingArtifacts.isEmpty && matchingFiles.isEmpty {
        ContentUnavailableView(term.isEmpty ? "暂无输出" : "没有匹配的输出",
          systemImage: "shippingbox")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(matchingArtifacts) { artifact in
              VStack(alignment: .leading, spacing: 6) {
                Button {
                  NSWorkspace.shared.activateFileViewerSelecting([artifact.directory])
                } label: {
                  Label(artifact.title, systemImage: "folder")
                    .frame(maxWidth: .infinity, alignment: .leading).lineLimit(2)
                }
                .buttonStyle(.plain)
                .disabled(!FileManager.default.fileExists(atPath: artifact.directory.path))
                ForEach(artifact.outputs.filter { term.isEmpty
                  || artifact.title.localizedStandardContains(term)
                  || $0.name.localizedStandardContains(term)
                  || $0.title.localizedStandardContains(term) }) { output in
                  Button {
                    if output.kind == .log { previewLog(output) }
                    else { NSWorkspace.shared.open(output.url) }
                  } label: {
                    Label(output.title, systemImage: output.kind == .log ? "doc.text" : "shippingbox")
                      .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                      .padding(.leading, 16)
                  }
                  .buttonStyle(.plain).help(output.name)
                  .disabled(!output.isAvailable)
                }
              }
            }
            ForEach(matchingFiles) { file in
              Button { openFile(file) } label: {
                VStack(alignment: .leading, spacing: 2) {
                  Label(file.title, systemImage: "doc")
                  Text(file.path).appFont(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
              }
              .buttonStyle(.plain).help(file.url.path)
            }
          }.appFont(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
      }
    }
    .frame(width: 316)
    .background(.regularMaterial)
  }
}
