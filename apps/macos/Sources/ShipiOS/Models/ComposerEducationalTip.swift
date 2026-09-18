import Foundation

enum ComposerEducationalTipAction: Equatable {
  case prefill(String)
  case settings(SettingsPage)
  case plugins
  case automations
  case newTask
}

struct ComposerEducationalTip: Identifiable, Equatable {
  let id: String
  let content: String
  let actionLabel: String
  let action: ComposerEducationalTipAction

  static let planMode = Self(
    id: "plan-mode",
    content: "在开始复杂任务前，让 ShipiOS 先制定计划。",
    actionLabel: "制定计划",
    action: .prefill("请先为这个任务制定计划，再开始修改。"))

  static let skills = Self(
    id: "skills",
    content: "试试适合编写、研究或表格工作的专用技能。",
    actionLabel: "浏览技能",
    action: .settings(.skills))

  static let steering = Self(
    id: "steering",
    content: "ShipiOS 工作时，也可以告诉它要调整什么。",
    actionLabel: "添加到消息",
    action: .prefill("请调整当前做法："))

  static let scheduledTasks = Self(
    id: "scheduled-tasks",
    content: "创建定时任务，自动处理重复工作。",
    actionLabel: "安排任务",
    action: .automations)

  static let plugins = Self(
    id: "plugins",
    content: "浏览插件，连接更多常用工具。",
    actionLabel: "浏览插件",
    action: .plugins)

  static let multipleThreads = Self(
    id: "multiple-active-threads",
    content: "ShipiOS 可以同时处理多个任务。",
    actionLabel: "新建任务",
    action: .newTask)

  static let notifications = Self(
    id: "notifications",
    content: "任务完成或需要你处理时接收通知。",
    actionLabel: "启用通知",
    action: .settings(.notifications))

  static let computerUse = Self(
    id: "computer-use",
    content: "通过电脑使用功能操作 Mac 上的应用。",
    actionLabel: "设置",
    action: .settings(.computerUse))

  static let supported: [Self] = [
    .planMode, .skills, .steering, .scheduledTasks, .plugins, .multipleThreads,
    .notifications, .computerUse,
  ]
}
