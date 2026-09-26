import SwiftUI

/// A task-local summary assembled only from records ShipiOS actually owns.
struct TaskSummaryView: View {
  let task: WorkspaceTask
  let runs: [AgentRun]
  let library: WorkspaceLibrary
  let close: () -> Void

  private var latestPlan: CodexPlan? {
    runs.reversed().compactMap(\.codexPlan).first
  }

  private var attachments: [String] {
    runs.flatMap { run in
      (library.runFiles[run.id] ?? []).map(\.name)
        + (library.runImages[run.id] ?? []).map(\.name)
    }
  }

  private var usage: TaskModelUsage? {
    library.modelUsageRecords.filter { $0.taskID == task.id }.groupedByTask.first
  }

  var body: some View {
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
          if let latestPlan { CodexPlanView(plan: latestPlan) }
          if !attachments.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
              Label("附件", systemImage: "paperclip").appFont(.headline)
              ForEach(Array(attachments.enumerated()), id: \.offset) { _, name in
                Text(name).appFont(.callout).lineLimit(2)
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
              description: Text("开始任务后，这里会显示计划、附件和用量。"))
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
      }
    }
    .frame(width: 316)
    .background(.regularMaterial)
  }
}
