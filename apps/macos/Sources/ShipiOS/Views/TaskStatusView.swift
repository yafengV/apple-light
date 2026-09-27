import AppKit
import SwiftUI

struct TaskStatusSnapshot {
  let taskID: String
  let title: String
  let codexThreadID: String?
  let recentContextInputTokens: Int?
  let recordedUsage: ModelTokenUsage?

  init(task: WorkspaceTask, records: [ModelUsageRecord], recentContextInputTokens: Int?) {
    taskID = task.id
    title = task.title
    codexThreadID = task.copyableCodexThreadID
    self.recentContextInputTokens = recentContextInputTokens
    recordedUsage = records.filter { $0.taskID == task.id }.groupedByTask.first?.usage
  }
}

struct TaskStatusView: View {
  let status: TaskStatusSnapshot
  let close: () -> Void

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
              LabeledContent("Codex 会话 ID", value: "尚未建立")
            }
          }
          Divider()
          VStack(alignment: .leading, spacing: 10) {
            Label("上下文与用量", systemImage: "gauge.with.dots.needle.33percent")
              .appFont(.headline)
            LabeledContent("最近一轮上下文输入", value:
              status.recentContextInputTokens.map { "\($0.formatted()) tokens" } ?? "暂无数据")
            if let usage = status.recordedUsage {
              LabeledContent("累计记录", value: "\(usage.totalTokens.formatted()) tokens")
              LabeledContent("输入 / 输出", value:
                "\(usage.inputTokens.formatted()) / \(usage.outputTokens.formatted())")
            } else {
              LabeledContent("累计记录", value: "暂无数据")
            }
            Text("服务未提供上下文窗口上限时，无法计算使用百分比。")
              .appFont(.caption).foregroundStyle(.secondary)
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
