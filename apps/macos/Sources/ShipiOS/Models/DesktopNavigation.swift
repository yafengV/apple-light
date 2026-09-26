import Foundation

struct DesktopCommand: Identifiable {
  let id: String
  let title: String
  let icon: String
  let defaultBindings: [ShortcutBinding]
  var defaultBinding: ShortcutBinding? { defaultBindings.first }
  init(id: String, title: String, icon: String, shortcut: String, alternates: [String] = []) {
    self.id = id
    self.title = title
    self.icon = icon
    self.defaultBindings = ([shortcut] + alternates).filter { !$0.isEmpty }.map(ShortcutBinding.init)
  }
  static func numberSlot(_ id: String) -> (isTab: Bool, index: Int)? {
    let isTab = id.hasPrefix("focus-tab-")
    let prefix = isTab ? "focus-tab-" : "focus-chat-"
    guard id.hasPrefix(prefix), let index = Int(id.dropFirst(prefix.count)), (1...9).contains(index)
    else { return nil }
    return (isTab, index)
  }

  static let all: [Self] = [
    .init(id: "palette", title: "命令菜单", icon: "command", shortcut: "⌘K"),
    .init(id: "palette-alternate", title: "命令菜单（备用）", icon: "command", shortcut: "⌘⇧P"),
    .init(id: "shortcuts", title: "快捷键设置", icon: "keyboard", shortcut: "⌘/"),
    .init(id: "sidebar", title: "显示或隐藏侧栏", icon: "sidebar.left", shortcut: "⌘B"),
    .init(id: "send", title: "发送消息", icon: "arrow.up", shortcut: "⌘↵"),
    .init(id: "new-alternate", title: "新任务（备用）", icon: "square.and.pencil", shortcut: "⌘⇧O"),
    .init(id: "find-next", title: "下一个匹配", icon: "arrow.down", shortcut: "⌘G"),
    .init(id: "find-previous", title: "上一个匹配", icon: "arrow.up", shortcut: "⌘⇧G"),
    .init(id: "previous-task", title: "上一个任务或标签", icon: "arrow.up", shortcut: "⌃⇧⇥", alternates: ["⌘⇧[", "⌘⌥←"]),
    .init(id: "next-task", title: "下一个任务或标签", icon: "arrow.down", shortcut: "⌃⇥", alternates: ["⌘⇧]", "⌘⌥→"]),
    .init(id: "next-attention", title: "下一个需关注的任务", icon: "circle.badge.exclamationmark", shortcut: "⌘⌥A"),
    .init(id: "clear-unread", title: "清除全部未读标记", icon: "checkmark.circle", shortcut: "⇧⎋"),
    .init(id: "back", title: "返回", icon: "arrow.left", shortcut: "⌘["),
    .init(id: "forward", title: "前进", icon: "arrow.right", shortcut: "⌘]"),
    .init(
      id: "bottom-panel", title: "切换底部面板", icon: "rectangle.bottomthird.inset.filled",
      shortcut: "⌘J"),
    .init(id: "model", title: "选择模型与推理强度", icon: "cpu", shortcut: "⌃⇧M"),
    .init(id: "fork", title: "分叉到新任务", icon: "arrow.triangle.branch", shortcut: ""),
    .init(id: "branch", title: "切换或创建分支", icon: "arrow.triangle.branch", shortcut: ""),
    .init(id: "settings", title: "设置", icon: "gearshape", shortcut: "⌘,"),
    .init(id: "pet", title: "显示或隐藏宠物", icon: "pawprint", shortcut: "⌥Space"),
    .init(id: "new", title: "新任务", icon: "square.and.pencil", shortcut: "⌘N"),
    .init(id: "search", title: "搜索任务", icon: "magnifyingglass", shortcut: ""),
    .init(id: "projects", title: "项目", icon: "folder", shortcut: ""),
    .init(id: "plugins", title: "插件", icon: "shippingbox", shortcut: ""),
    .init(id: "automations", title: "自动化", icon: "clock.arrow.circlepath", shortcut: ""),
    .init(id: "open", title: "打开文件夹…", icon: "folder.badge.plus", shortcut: "⌘O"),
    .init(id: "files", title: "搜索文件", icon: "doc.text.magnifyingglass", shortcut: "⌘P"),
    .init(id: "tree", title: "切换文件树", icon: "sidebar.right", shortcut: "⌘⇧E"),
    .init(id: "terminal", title: "切换终端", icon: "terminal", shortcut: "⌃`"),
    .init(
      id: "review", title: "切换审查面板", icon: "point.3.connected.trianglepath.dotted", shortcut: "⌘⌥B"),
    .init(id: "review-open", title: "打开审查标签", icon: "square.stack.3d.up", shortcut: "⌃⇧G"),
    .init(id: "browser", title: "显示或隐藏浏览器标签", icon: "globe", shortcut: ""),
    .init(id: "browser-new", title: "新建浏览器标签", icon: "plus", shortcut: "⌘T"),
    .init(id: "workspace-view", title: "切换完整与分栏视图", icon: "rectangle.split.2x1", shortcut: "⌘⇧F"),
    .init(id: "workspace-tabs", title: "显示或隐藏内容标签", icon: "rectangle.topthird.inset.filled", shortcut: "⌘⇧B"),
    .init(id: "workspace-swap-panes", title: "交换左侧和右侧面板", icon: "arrow.left.arrow.right", shortcut: ""),
    .init(id: "tab-close", title: "关闭当前标签", icon: "xmark", shortcut: ""),
    .init(id: "tab-close-others", title: "关闭其他标签", icon: "xmark.circle", shortcut: "⌘⌥W"),
    .init(id: "focus-tab-1", title: "聚焦标签 1", icon: "1.square", shortcut: "⌘1"),
    .init(id: "focus-chat-1", title: "切换到聊天 1", icon: "1.square", shortcut: "⌃1"),
    .init(id: "focus-tab-2", title: "聚焦标签 2", icon: "2.square", shortcut: "⌘2"),
    .init(id: "focus-chat-2", title: "切换到聊天 2", icon: "2.square", shortcut: "⌃2"),
    .init(id: "focus-tab-3", title: "聚焦标签 3", icon: "3.square", shortcut: "⌘3"),
    .init(id: "focus-chat-3", title: "切换到聊天 3", icon: "3.square", shortcut: "⌃3"),
    .init(id: "focus-tab-4", title: "聚焦标签 4", icon: "4.square", shortcut: "⌘4"),
    .init(id: "focus-chat-4", title: "切换到聊天 4", icon: "4.square", shortcut: "⌃4"),
    .init(id: "focus-tab-5", title: "聚焦标签 5", icon: "5.square", shortcut: "⌘5"),
    .init(id: "focus-chat-5", title: "切换到聊天 5", icon: "5.square", shortcut: "⌃5"),
    .init(id: "focus-tab-6", title: "聚焦标签 6", icon: "6.square", shortcut: "⌘6"),
    .init(id: "focus-chat-6", title: "切换到聊天 6", icon: "6.square", shortcut: "⌃6"),
    .init(id: "focus-tab-7", title: "聚焦标签 7", icon: "7.square", shortcut: "⌘7"),
    .init(id: "focus-chat-7", title: "切换到聊天 7", icon: "7.square", shortcut: "⌃7"),
    .init(id: "focus-tab-8", title: "聚焦标签 8", icon: "8.square", shortcut: "⌘8"),
    .init(id: "focus-chat-8", title: "切换到聊天 8", icon: "8.square", shortcut: "⌃8"),
    .init(id: "focus-tab-9", title: "聚焦标签 9", icon: "9.square", shortcut: "⌘9"),
    .init(id: "focus-chat-9", title: "切换到聊天 9", icon: "9.square", shortcut: "⌃9"),
    .init(id: "browser-address", title: "跳转到行或浏览器地址栏", icon: "link", shortcut: "⌘L"),
    .init(id: "browser-back", title: "浏览器后退", icon: "chevron.left", shortcut: "⌘←"),
    .init(id: "browser-forward", title: "浏览器前进", icon: "chevron.right", shortcut: "⌘→"),
    .init(id: "browser-reload", title: "重新加载网页", icon: "arrow.clockwise", shortcut: "⌘R"),
    .init(id: "browser-reload-origin", title: "忽略缓存重新加载网页", icon: "arrow.clockwise", shortcut: "⌘⇧R"),
    .init(id: "browser-copy", title: "复制浏览器网址", icon: "doc.on.doc", shortcut: "⌘⇧C"),
    .init(id: "browser-close", title: "关闭浏览器标签", icon: "xmark", shortcut: ""),
    .init(id: "browser-reopen", title: "重新打开关闭的浏览器标签", icon: "arrow.uturn.backward", shortcut: "⌘⇧T"),
    .init(id: "find", title: "在任务中查找", icon: "text.magnifyingglass", shortcut: "⌘F"),
    .init(id: "rename", title: "重命名任务…", icon: "pencil", shortcut: "⌘⌥R"),
    .init(id: "pin", title: "置顶 / 取消置顶任务", icon: "pin", shortcut: "⌘⌥P"),
    .init(id: "unread", title: "标记为未读", icon: "circle.fill", shortcut: "⌘⇧U"),
    .init(id: "archive", title: "归档任务", icon: "archivebox", shortcut: "⌘⇧A"),
    .init(id: "doctor", title: "检查开发环境", icon: "stethoscope", shortcut: ""),
    .init(id: "build", title: "构建 iOS 项目", icon: "hammer", shortcut: "⌘⇧D"),
    .init(id: "stop", title: "停止执行", icon: "stop", shortcut: "⌘."),
    .init(id: "approval-approve", title: "批准当前请求", icon: "checkmark.shield", shortcut: "↵"),
    .init(id: "approval-decline", title: "拒绝当前请求", icon: "xmark.shield", shortcut: "⎋"),
  ]
}

enum DesktopCommandGroup: String, CaseIterable {
  case chat, navigation, panels, project, configure, app

  var title: String {
    switch self {
    case .chat: "会话"
    case .navigation: "导航"
    case .panels: "面板"
    case .project: "项目"
    case .configure: "配置"
    case .app: "应用"
    }
  }
}

extension DesktopCommand {
  var group: DesktopCommandGroup {
    if id.hasPrefix("focus-chat-") { return .navigation }
    if id.hasPrefix("focus-tab-") || id.hasPrefix("browser-") { return .panels }
    return switch id {
    case "new", "new-alternate", "send", "model", "fork", "find", "find-next", "find-previous",
      "rename", "pin", "unread", "archive", "stop", "approval-approve", "approval-decline": .chat
    case "previous-task", "next-task", "next-attention", "clear-unread", "back", "forward",
      "search", "sidebar": .navigation
    case "bottom-panel", "files", "tree", "terminal", "review", "review-open", "browser",
      "workspace-view", "workspace-tabs", "workspace-swap-panes", "tab-close", "tab-close-others": .panels
    case "projects", "open", "branch", "doctor", "build": .project
    case "settings", "shortcuts", "plugins", "automations": .configure
    default: .app
    }
  }
}

enum SettingsPage: String, CaseIterable, Identifiable {
  case general, profile, appearance, pets, personalization, memories, model, agent, git, codeReview, environments, usage, shortcuts, notifications, browser, computerUse, connections, mcpServers, hooks, plugins, skills, worktrees, archived, runtime
  var id: String { rawValue }
  var title: String {
    switch self {
    case .general: "通用"
    case .profile: "个人资料"
    case .appearance: "外观"
    case .pets: "宠物"
    case .personalization: "个性化"
    case .memories: "记忆"
    case .model: "模型与 API"
    case .agent: "Agent"
    case .git: "Git"
    case .codeReview: "代码审查"
    case .environments: "环境"
    case .usage: "用量"
    case .shortcuts: "快捷键"
    case .notifications: "通知"
    case .browser: "浏览器"
    case .computerUse: "电脑使用"
    case .connections: "连接"
    case .mcpServers: "MCP 服务器"
    case .hooks: "Hooks"
    case .plugins: "插件"
    case .skills: "技能"
    case .worktrees: "工作树"
    case .archived: "已归档任务"
    case .runtime: "运行时"
    }
  }
  var icon: String {
    switch self {
    case .general: "gearshape"
    case .profile: "person.text.rectangle"
    case .appearance: "paintpalette"
    case .pets: "pawprint"
    case .personalization: "person.crop.circle"
    case .memories: "brain"
    case .model: "cpu"
    case .agent: "sparkles"
    case .git: "arrow.triangle.branch"
    case .codeReview: "checkmark.bubble"
    case .environments: "shippingbox"
    case .usage: "chart.bar.xaxis"
    case .shortcuts: "keyboard"
    case .notifications: "bell"
    case .browser: "globe"
    case .computerUse: "macbook.and.iphone"
    case .connections: "network"
    case .mcpServers: "server.rack"
    case .hooks: "point.topleft.down.to.point.bottomright.curvepath"
    case .plugins: "shippingbox"
    case .skills: "wand.and.stars"
    case .worktrees: "arrow.triangle.branch"
    case .archived: "archivebox"
    case .runtime: "desktopcomputer"
    }
  }
}

struct TaskLocation: Equatable {
  let project: String
  let run: String?
}
