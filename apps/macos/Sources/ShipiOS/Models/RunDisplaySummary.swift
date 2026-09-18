import Foundation

extension AgentRun {
  var displaySummary: String {
    switch status {
    case "queued", "running":
      return kind == "doctor" ? "正在检查 Xcode 与项目环境…" : "正在构建项目，完成后会显示编译结果。"
    case "succeeded":
      return kind == "doctor" ? "环境检查完成。Xcode 可以正常运行。" : "构建已完成，编译通过。你可以查看日志、诊断与构建产物。"
    case "cancelled": return "已停止这次执行。保留了执行记录，你可以调整配置后继续。"
    case "interrupted": return "这次执行已中断。记录已恢复，没有自动重新执行。"
    default: return result?["message"].text ?? "执行未完成。请查看诊断或日志，调整配置后重试。"
    }
  }
}
