import AppKit
import SwiftUI

/// A task-local summary assembled only from records ShipiOS actually owns.
struct TaskSummaryView: View {
  @State private var outputPreview: TaskSummaryOutputFile?
  @State private var selectedPullRequest: (taskID: String, request: GitHubPullRequest)?
  @State private var showingOutputs = false
  @State private var linkedFiles: [TaskSummaryLinkedFile] = []
  let task: WorkspaceTask
  let runs: [AgentRun]
  let library: WorkspaceLibrary
  let openPlan: (String) -> Void
  let openAllSources: () -> Void
  let openFile: (FileAttachment) -> Void
  let openImage: (ImageAttachment, [ImageAttachment]) -> Void
  let openExternal: (URL) -> Void
  let addFile: () -> Void
  let addImage: () -> Void
  let canAddFile: Bool
  let canAddImage: Bool
  let onPullRequestUpdated: (GitHubPullRequest) -> Void
  let browserTabs: [TaskSummaryBrowserTab]
  let focusBrowserTab: (UUID) -> Void
  let rootForRun: (AgentRun) -> URL?
  let openOutputFile: (TaskSummaryLinkedFile) -> Void
  let close: () -> Void

  private var latestPlanDocument: (runID: String, document: CodexPlanDocument)? {
    runs.reversed().compactMap { run in
      run.codexPlanDocument.map { (run.id, $0) }
    }.first
  }

  private var usage: TaskModelUsage? {
    library.modelUsageRecords.filter { $0.taskID == task.id }.groupedByTask.first
  }

  var body: some View {
    Group {
      if let selection = selectedPullRequest, selection.taskID == task.id {
        TaskPullRequestDetailView(request: selection.request,
          root: URL(fileURLWithPath: task.project, isDirectory: true),
          openExternal: openExternal,
          onRefresh: onPullRequestUpdated,
          back: { selectedPullRequest = nil },
          close: { selectedPullRequest = nil; close() })
      } else if showingOutputs {
        TaskSummaryOutputsView(artifacts: runs.summaryArtifacts, linkedFiles: linkedFiles,
          previewLog: { outputPreview = $0 }, openFile: openOutputFile,
          refresh: refreshLinkedFiles,
          back: { showingOutputs = false }, close: close)
      } else {
        summaryContent
      }
    }
    .onChange(of: task.id) { _, _ in selectedPullRequest = nil; showingOutputs = false }
    .onChange(of: runs, initial: true) { _, current in
      linkedFiles = TaskSummaryLinkedFiles.collect(current, rootForRun: rootForRun)
    }
  }

  private func refreshLinkedFiles() {
    linkedFiles = TaskSummaryLinkedFiles.collect(runs, rootForRun: rootForRun)
  }

  @ViewBuilder private var summaryContent: some View {
    let sources = runs.summarySources(in: library)
    let pullRequests = (library.taskPullRequests[task.id] ?? []).filter { $0.validatedURL != nil }
    let artifacts = runs.summaryArtifacts
    let sourceImages = sources.compactMap { source -> ImageAttachment? in
      if case .image(let image) = source { return image }
      return nil
    }
    VStack(spacing: 0) {
      HStack {
        Text("摘要").appFont(.headline)
        Spacer()
        Button(action: close) { Image(systemName: "xmark") }
          .buttonStyle(.plain)
          .help("关闭摘要")
          .accessibilityLabel("关闭摘要")
      }
      .padding(.horizontal, 16).padding(.vertical, 13)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          VStack(alignment: .leading, spacing: 6) {
            Text(task.title).appFont(.headline)
            Text("\(runs.count) 次运行")
              .appFont(.caption).foregroundStyle(.secondary)
            if let latest = runs.last {
              Label(latest.statusLabel, systemImage: latest.isActive ? "circle.dotted" : "checkmark.circle")
                .appFont(.caption).foregroundStyle(.secondary)
            }
          }
          if let latestPlanDocument {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
              Label("计划", systemImage: "text.document").appFont(.headline)
              Button { openPlan(latestPlanDocument.runID) } label: {
                HStack {
                  Text(latestPlanDocument.document.title).lineLimit(2)
                  Spacer()
                  Image(systemName: "arrow.up.right")
                }.frame(maxWidth: .infinity)
              }
              .buttonStyle(.plain)
              .help("打开计划文档")
            }
          }
          if !pullRequests.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
              HStack {
                Label("Pull requests", systemImage: "arrow.triangle.pullrequest").appFont(.headline)
                Text(pullRequests.count.formatted()).appFont(.caption).foregroundStyle(.secondary)
              }
              ForEach(pullRequests, id: \.url) { request in
                if let url = request.validatedURL {
                  Button { selectedPullRequest = (task.id, request) } label: {
                    HStack(alignment: .top, spacing: 8) {
                      Text("#\(request.number)").foregroundStyle(.secondary)
                      VStack(alignment: .leading, spacing: 3) {
                        Text(request.title).lineLimit(2)
                        Text("\(request.statusLabel) · \(request.headRefName) → \(request.baseRefName)")
                          .appFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                      }
                      Spacer(minLength: 0)
                      Image(systemName: "arrow.up.right").foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                  }
                  .buttonStyle(.plain)
                  .help("查看 PR 详情")
                  .contextMenu {
                    Button("复制链接") {
                      NSPasteboard.general.clearContents()
                      NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                    Button("在浏览器中打开") { openExternal(url) }
                  }
                }
              }
            }.appFont(.callout)
          }
          if !sources.isEmpty || task.project.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
              HStack {
                Label("来源", systemImage: "square.stack").appFont(.headline)
                if !sources.isEmpty {
                  Text(sources.count.formatted()).appFont(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                  Button("添加文件…", systemImage: "doc.badge.plus", action: addFile)
                    .disabled(!canAddFile)
                  Button("添加图片…", systemImage: "photo", action: addImage)
                    .disabled(!canAddImage)
                } label: {
                  Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .help("添加来源")
                .accessibilityLabel("添加来源")
              }
              TaskSourcesListView(sources: Array(sources.prefix(3)), images: sourceImages,
                openFile: openFile, openImage: openImage, openExternal: openExternal)
              if sources.count > 3 {
                Button("查看全部 \(sources.count.formatted()) 个来源", action: openAllSources)
                  .buttonStyle(.plain)
                  .foregroundStyle(.tint)
                  .accessibilityLabel("查看全部来源")
              }
            }
            .appFont(.callout)
          }
          if !browserTabs.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
              HStack {
                Label("浏览器标签", systemImage: "globe").appFont(.headline)
                Text(browserTabs.count.formatted()).appFont(.caption).foregroundStyle(.secondary)
              }
              ForEach(browserTabs) { tab in
                Button { focusBrowserTab(tab.id) } label: {
                  HStack(spacing: 8) {
                    Image(systemName: "globe").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                      Text(tab.title).lineLimit(1)
                      Text(tab.subtitle).appFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").foregroundStyle(.secondary)
                  }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help("聚焦浏览器标签")
                .accessibilityLabel("聚焦浏览器标签：\(tab.title)")
              }
            }.appFont(.callout)
          }
          if !artifacts.isEmpty || !linkedFiles.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
              HStack {
                Label("输出", systemImage: "shippingbox").appFont(.headline)
                Text((artifacts.reduce(0) { $0 + 1 + $1.outputs.count } + linkedFiles.count).formatted())
                  .appFont(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("查看全部") { refreshLinkedFiles(); showingOutputs = true }
                  .buttonStyle(.plain).foregroundStyle(.tint)
              }
              ForEach(artifacts) { artifact in
                VStack(alignment: .leading, spacing: 6) {
                  Button {
                    NSWorkspace.shared.activateFileViewerSelecting([artifact.directory])
                  } label: {
                    Label(artifact.title, systemImage: "folder")
                      .appFont(.callout).lineLimit(2)
                      .frame(maxWidth: .infinity, alignment: .leading)
                  }
                  .buttonStyle(.plain)
                  .help("在 Finder 中显示运行目录")
                  .disabled(!FileManager.default.fileExists(atPath: artifact.directory.path))
                  ForEach(artifact.outputs) { output in
                    Button {
                      if output.kind == .log { outputPreview = output }
                      else { NSWorkspace.shared.open(output.url) }
                    } label: {
                      Label(output.title, systemImage: output.kind == .log ? "doc.text" : "shippingbox")
                        .appFont(.callout).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 16)
                    }
                    .buttonStyle(.plain)
                    .help(output.name)
                  }
                }
              }
              ForEach(linkedFiles.prefix(3)) { file in
                Button { openOutputFile(file) } label: {
                  Label(file.title, systemImage: "doc")
                    .appFont(.callout).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain).help(file.path)
              }
            }
          }
          if let usage {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
              Label("用量", systemImage: "chart.bar").appFont(.headline)
              Text("总计 \(usage.usage.totalTokens.formatted()) tokens")
              Text("输入 \(usage.usage.inputTokens.formatted()) · 输出 \(usage.usage.outputTokens.formatted())")
                .foregroundStyle(.secondary)
            }.appFont(.callout)
          }
          if runs.isEmpty {
            ContentUnavailableView("暂无会话摘要", systemImage: "text.alignleft",
              description: Text("开始任务后，这里会显示计划、产物和用量。"))
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
      }
    }
    .frame(width: 316)
    .background(.regularMaterial)
    .sheet(item: $outputPreview) { output in
      TaskSummaryOutputPreview(output: output)
    }
  }
}
