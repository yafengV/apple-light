import AppKit
import SwiftUI

struct CounterDeliveryCard: View {
  @Bindable var store: WorkspaceStore
  let taskID: String?

  var body: some View {
    if let taskID, store.counterProject(taskID: taskID) != nil || store.library.counterDeliveries[taskID] != nil {
      let record = store.library.counterDeliveries[taskID]
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Label(record?.phase.title ?? "HelloShipiOS 计数器验收", systemImage: record?.phase == .succeeded ? "checkmark.circle" : "testtube.2")
            .appFont(.caption, weight: .semibold)
          Spacer()
          if record?.phase.isActive == true {
            ProgressView().controlSize(.small)
            Button("停止") { store.stopCounterDelivery(taskID: taskID) }
          } else {
            Button("验证计数器") { store.beginCounterDelivery(taskID: taskID, repairFailures: false) }
              .disabled(!store.canVerifyCounter(taskID: taskID))
          }
        }
        Text("固定 UI 断言：0 → 1 → 2 → 重置 0 · 专用 iOS 26.2 设备")
          .appFont(.caption).foregroundStyle(.secondary)
        if let record {
          if record.phase == .blocked {
            Text("请先恢复固定验收合同或工程访问；未请求模型修复。")
              .appFont(.caption).foregroundStyle(.secondary)
          }
          if !record.message.isEmpty {
            Text(String(record.message.prefix(300))).appFont(.caption).lineLimit(3).textSelection(.enabled)
          }
          if !record.verifications.isEmpty {
            DisclosureGroup("验证记录 · \(record.verifications.count) 次 · 自动修复 \(record.repairs)/2 轮") {
              ForEach(record.verifications) { run in
                VStack(alignment: .leading, spacing: 3) {
                  let build = run.result?["steps"].items.first { $0["stage"].text == "build" }
                  Text(build?["exitCode"].int.map { $0 == 0 ? "构建成功" : "构建失败 · 退出码 \($0)" } ?? "构建未执行")
                  if let diagnostic = run.result?["command"]["diagnostics"].items.first(where: { $0["severity"].text == "error" }),
                    let message = diagnostic["message"].text {
                    Text(String(message.prefix(1000))).foregroundStyle(.red).textSelection(.enabled)
                  }
                  let summary = run.result?["testSummary"]
                  if let count = summary?["totalTestCount"].int {
                    Text("UI：\(count) 执行 · \(summary?["passedTests"].int ?? 0) 通过 · \(summary?["failedTests"].int ?? 0) 失败 · \(summary?["skippedTests"].int ?? 0) 跳过")
                  } else {
                    Text(run.result?["steps"].items.contains { $0["stage"].text == "test" } == true
                      ? "UI 未取得有效用例结果" : "UI 未运行")
                  }
                  if let path = run.result?["artifactDirectory"].text {
                    Button("查看工件") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                      .buttonStyle(.plain).foregroundStyle(.tint)
                  }
                }.appFont(.caption).padding(.vertical, 5)
              }
            }.appFont(.caption)
          }
          if !record.phase.isActive {
            HStack {
              if record.phase == .failed || record.phase == .interrupted || record.phase == .cancelled {
                Button("修复并验证（最多 2 轮）") {
                  store.beginCounterDelivery(taskID: taskID, repairFailures: true)
                }.disabled(!store.canRepairCounter(taskID: taskID))
                Text("可直接接管工程").foregroundStyle(.secondary)
              }
              Spacer()
              Button("导出验证报告") { Task { await store.exportCounterDelivery(taskID: taskID) } }
            }.appFont(.caption)
          }
        }
      }.padding(12).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityIdentifier("counter-delivery-card")
    }
  }
}
