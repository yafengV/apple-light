import AppKit
import SwiftUI

struct TaskStatusSnapshot {
  let taskID: String
  let title: String
  let codexThreadID: String?
  let recentContextInputTokens: Int?
  let contextWindow: Int?
  let currentModel: String
  let recentUsageModel: String?
  let recentUsageInputTokens: Int?
  let usesCodexCore: Bool
  let recordedUsage: ModelTokenUsage?

  var contextFraction: Double? { contextFraction(for: contextWindow) }

  func contextFraction(for window: Int?) -> Double? {
    guard let recentContextInputTokens, let window, window > 0,
      recentContextInputTokens >= 0, recentContextInputTokens <= window,
      recentUsageModel == currentModel, recentUsageInputTokens == recentContextInputTokens else {
      return nil
    }
    return Double(recentContextInputTokens) / Double(window)
  }

  init(task: WorkspaceTask, records: [ModelUsageRecord], recentContextInputTokens: Int?,
    currentModel: String = "", contextWindow: Int? = nil, usesCodexCore: Bool = false) {
    taskID = task.id
    title = task.title
    codexThreadID = task.copyableCodexThreadID
    self.recentContextInputTokens = recentContextInputTokens
    self.contextWindow = contextWindow
    self.currentModel = currentModel
    self.usesCodexCore = usesCodexCore
    let latest = records.filter { $0.taskID == task.id }.max { $0.date < $1.date }
    recentUsageModel = latest?.model
    recentUsageInputTokens = latest?.usage.inputTokens
    recordedUsage = records.filter { $0.taskID == task.id }.groupedByTask.first?.usage
  }
}

struct TaskStatusView: View {
  let status: TaskStatusSnapshot
  var loadContextWindow: (() async -> Int?)? = nil
  let close: () -> Void
  @State private var fetchedContext: (identity: String, window: Int)?
  @State private var loadingContextIdentity: String?

  private var contextIdentity: String { status.taskID + "|" + status.currentModel }
  private var contextWindow: Int? {
    if fetchedContext?.identity == contextIdentity { return fetchedContext?.window }
    return status.contextWindow
  }
  private var contextFraction: Double? { status.contextFraction(for: contextWindow) }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("会话状态").appFont(.headline)
        Spacer()
        Button(action: close) { Image(systemName: "xmark") }
          .buttonStyle(.plain).help("关闭状态")
          .accessibilityLabel("关闭状态")
      }
      .padding(18)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          VStack(alignment: .leading, spacing: 10) {
            Text(status.title).appFont(.headline).lineLimit(2)
            identifier("ShipiOS 任务 ID", value: status.taskID)
            if let id = status.codexThreadID {
              identifier("Codex 会话 ID", value: id)
            } else {
              LabeledContent("Codex 会话 ID", value: status.usesCodexCore ? "尚未建立" : "不适用")
            }
          }
          Divider()
          VStack(alignment: .leading, spacing: 10) {
            Label("上下文与用量", systemImage: "gauge.with.dots.needle.33percent")
              .appFont(.headline)
            LabeledContent("最近一轮上下文输入", value:
              status.recentContextInputTokens.map { "\($0.formatted()) tokens" } ?? "暂无数据")
            if let fraction = contextFraction, let window = contextWindow {
              ProgressView(value: fraction)
                .accessibilityLabel("上下文窗口用量")
                .accessibilityValue("约 \(Int((fraction * 100).rounded()))%")
              Text("约 \(Int((fraction * 100).rounded()))% · 模型窗口 \(window.formatted()) tokens")
                .appFont(.caption).foregroundStyle(.secondary)
            }
            if let usage = status.recordedUsage {
              LabeledContent("累计记录", value: "\(usage.totalTokens.formatted()) tokens")
              LabeledContent("输入 / 输出", value:
                "\(usage.inputTokens.formatted()) / \(usage.outputTokens.formatted())")
            } else {
              LabeledContent("累计记录", value: "暂无数据")
            }
            if loadingContextIdentity == contextIdentity {
              ProgressView("正在获取模型窗口…").controlSize(.small)
            } else if contextFraction == nil {
              Text("暂无可与最近一轮用量匹配的模型窗口数据，无法计算百分比。")
                .appFont(.caption).foregroundStyle(.secondary)
            }
          }
          Divider()
          VStack(alignment: .leading, spacing: 8) {
            Label("额度", systemImage: "chart.bar")
              .appFont(.headline)
            Text("ShipiOS 当前未获取独立 API 服务的额度与重置时间。请以服务商提供的信息为准。")
              .foregroundStyle(.secondary)
          }
        }
        .appFont(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
      }
    }
    .frame(width: 440, height: 410)
    .task(id: contextIdentity) {
      guard status.contextWindow == nil, status.recentContextInputTokens != nil,
        let loadContextWindow else { return }
      let identity = contextIdentity
      loadingContextIdentity = identity
      let window = await loadContextWindow()
      guard !Task.isCancelled else { return }
      if let window { fetchedContext = (identity, window) }
      if loadingContextIdentity == identity { loadingContextIdentity = nil }
    }
  }

  private func identifier(_ label: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label).foregroundStyle(.secondary)
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(value).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
        Spacer(minLength: 0)
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(value, forType: .string)
        } label: {
          Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.plain).help("复制\(label)")
        .accessibilityLabel("复制\(label)")
      }
    }
  }
}
