import Charts
import SwiftUI

private enum UsagePeriod: String, CaseIterable, Identifiable {
  case week = "7 天"
  case month = "30 天"
  case all = "全部"
  var id: String { rawValue }
  var days: Int? { self == .week ? 7 : self == .month ? 30 : nil }
}

private struct DailyUsage: Identifiable {
  let date: Date
  let tokens: Int
  var id: Date { date }
}

struct UsageSettingsView: View {
  let store: WorkspaceStore
  @State private var period = UsagePeriod.month
  @State private var expandedRunID: String?

  private var records: [ModelUsageRecord] {
    guard let days = period.days,
      let cutoff = Calendar.current.date(byAdding: .day, value: -days + 1, to: Calendar.current.startOfDay(for: Date()))
    else { return store.library.modelUsageRecords }
    return store.library.modelUsageRecords.filter { $0.date >= cutoff }
  }
  private var input: Int { records.reduce(0) { $0 + $1.usage.inputTokens } }
  private var output: Int { records.reduce(0) { $0 + $1.usage.outputTokens } }
  private var total: Int { records.reduce(0) { $0 + $1.usage.totalTokens } }
  private var topTasks: [TaskModelUsage] { Array(records.groupedByTask.prefix(5)) }
  private var daily: [DailyUsage] {
    Dictionary(grouping: records) { Calendar.current.startOfDay(for: $0.date) }
      .map { DailyUsage(date: $0.key, tokens: $0.value.reduce(0) { $0 + $1.usage.totalTokens }) }
      .sorted { $0.date < $1.date }
  }
  private var recordedRunCount: Int { store.library.modelUsageRecords.count }
  private var completedRunCount: Int {
    store.library.chatRuns.filter { !$0.isActive }.count
  }

  var body: some View {
    Form {
      Section {
        Picker("时间范围", selection: $period) {
          ForEach(UsagePeriod.allCases) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.segmented).settingsSearchTarget(.usagePeriod)
      }
      Section("Token 用量") {
        HStack(spacing: 32) {
          metric("总计", total)
          metric("输入", input)
          metric("输出", output)
        }.frame(maxWidth: .infinity, alignment: .leading)
        if daily.isEmpty {
          ContentUnavailableView(
            "暂无服务用量", systemImage: "chart.bar.xaxis",
            description: Text("在“模型与 API”中启用 token 用量，并完成一次支持该字段的模型会话。"))
        } else {
          Chart(daily) { day in
            BarMark(
              x: .value("日期", day.date, unit: .day),
              y: .value("Tokens", day.tokens))
              .foregroundStyle(Color.accentColor.gradient)
          }.frame(height: 180)
        }
      }
      .settingsSearchTarget(.usageTokens)
      Section("最近会话") {
        if records.isEmpty {
          Text("服务尚未返回可记录的 token 统计。" ).foregroundStyle(.secondary)
        } else {
          ForEach(Array(records.prefix(10))) { record in
            DisclosureGroup(
              isExpanded: Binding(
                get: { expandedRunID == record.runID },
                set: { expandedRunID = $0 ? record.runID : nil })
            ) {
              VStack(alignment: .leading, spacing: 7) {
                LabeledContent("模型", value: record.model)
                LabeledContent("推理强度", value: record.reasoningTitle)
                LabeledContent("输入 token", value: record.usage.inputTokens.formatted())
                LabeledContent("输出 token", value: record.usage.outputTokens.formatted())
                if let cached = record.usage.cachedInputTokens {
                  LabeledContent("缓存输入", value: cached.formatted())
                }
                if let reasoning = record.usage.reasoningOutputTokens {
                  LabeledContent("推理输出", value: reasoning.formatted())
                }
                if record.duration > 0 {
                  LabeledContent(
                    "会话耗时",
                    value: "\(record.duration.formatted(.number.precision(.fractionLength(1)))) 秒")
                }
                Button("打开会话") {
                  Task { await store.openUsageRecord(taskID: record.taskID, runID: record.runID) }
                }
              }.appFont(.caption).padding(.top, 6).padding(.leading, 4)
            } label: {
              HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                  Text(record.taskTitle).lineLimit(1)
                  Text("\(record.projectTitle) · \(record.model) · 推理 \(record.reasoningTitle) · \(record.date.formatted(date: .abbreviated, time: .shortened))")
                    .appFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text("\(record.usage.totalTokens.formatted()) tokens")
                  .monospacedDigit().foregroundStyle(.secondary)
              }
            }
          }
        }
      }
      .settingsSearchTarget(.usageRecent)
      Section("高用量任务") {
        if topTasks.isEmpty {
          Text("记录 token 用量后，这里会显示当前时间范围内用量最高的任务。")
            .foregroundStyle(.secondary)
        } else {
          ForEach(topTasks) { task in
            Button {
              Task { await store.openUsageRecord(taskID: task.taskID) }
            } label: {
              HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                  Text(task.taskTitle).lineLimit(1)
                  Text("\(task.projectTitle) · \(task.sessionCount) 次已记录会话")
                    .appFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text("\(task.usage.totalTokens.formatted()) tokens")
                  .monospacedDigit().foregroundStyle(.secondary)
                Image(systemName: "chevron.right").appFont(.caption).foregroundStyle(.tertiary)
              }.contentShape(Rectangle())
            }.buttonStyle(.plain)
          }
        }
      }
      .settingsSearchTarget(.usageTopTasks)
      Section("数据范围") {
        LabeledContent("已记录会话", value: "\(recordedRunCount) / \(completedRunCount)")
        Text("这里只汇总独立 API 服务在流式响应中返回的 token 数。额度、价格和账单由你的服务商管理，ShipiOS 不做估算。旧会话或未返回 usage 的服务不会出现在图表中。")
          .appFont(.caption).foregroundStyle(.secondary)
      }
    }.settingsFormStyle().appSurface()
  }

  private func metric(_ title: String, _ value: Int) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).appFont(.caption).foregroundStyle(.secondary)
      Text(value.formatted()).appFont(size: 22, weight: .semibold).monospacedDigit()
    }
  }
}
