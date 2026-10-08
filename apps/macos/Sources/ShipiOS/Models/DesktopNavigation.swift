import Foundation

struct DesktopCommand: Identifiable {
  // Theme is a command-menu contributor, without a global shortcut command.
  static let theme = Self(id: "theme", title: "主题", icon: "sun.max", shortcut: "")
  let id: String
  let title: String
  let icon: String
  let defaultBindings: [ShortcutBinding]
  var allowsBareModifiers: Bool {
    ["globalDictationHold", "globalDictationSingleTap", "realtimeVoice"].contains(id)
  }
  var isOSGlobal: Bool { allowsBareModifiers || ["pet", "popout"].contains(id) }
  var isRecentTaskNavigation: Bool { ["previous-recent-task", "next-recent-task"].contains(id) }
  var isTabNavigation: Bool { ["previous-tab", "next-tab"].contains(id) }
  static func allowsSharedBinding(_ left: String, _ right: String) -> Bool {
    for direction in ["previous", "next"] {
      if Set([left, right]) == Set(["\(direction)-tab", "\(direction)-task"])
        || Set([left, right]) == Set(["\(direction)-tab", "\(direction)-recent-task"]) { return true }
    }
    return false
  }
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

  static func recentChatSlot(_ id: String) -> Int? {
    let prefix = "recent-chat-"
    guard id.hasPrefix(prefix), let number = Int(id.dropFirst(prefix.count)),
      (1...6).contains(number) else { return nil }
    return number - 1
  }

  static func environmentActionSlot(_ id: String) -> Int? {
    let prefix = "environment-action-"
    guard id.hasPrefix(prefix), let number = Int(id.dropFirst(prefix.count)),
      (1...9).contains(number) else { return nil }
    return number - 1
  }

  static let all: [Self] = [
    .init(id: "palette", title: "命令菜单", icon: "command", shortcut: "⌘K", alternates: ["⌘⇧P"]),
    .init(id: "shortcuts", title: "快捷键设置", icon: "keyboard", shortcut: "⌘/"),
    .init(id: "sidebar", title: "显示或隐藏侧栏", icon: "sidebar.left", shortcut: "⌘B"),
    .init(id: "send", title: "发送消息", icon: "arrow.up", shortcut: "⌘↵"),
    .init(id: "steer-prompt", title: "引导当前运行", icon: "arrow.turn.up.right", shortcut: ""),
    .init(id: "queue-prompt", title: "加入队列", icon: "text.badge.plus", shortcut: ""),
    .init(id: "new-standalone", title: "无项目新任务", icon: "square.and.pencil", shortcut: "⌘⌥O"),
    .init(id: "find-next", title: "下一个匹配", icon: "arrow.down", shortcut: "⌘G"),
    .init(id: "find-previous", title: "上一个匹配", icon: "arrow.up", shortcut: "⌘⇧G"),
    .init(id: "previous-task", title: "上一个聊天", icon: "arrow.up", shortcut: "⌘⇧[", alternates: ["⌘⌥←"]),
    .init(id: "next-task", title: "下一个聊天", icon: "arrow.down", shortcut: "⌘⇧]", alternates: ["⌘⌥→"]),
    .init(id: "previous-recent-task", title: "上一个最近访问的聊天", icon: "clock.arrow.circlepath", shortcut: "⌃⇧⇥"),
    .init(id: "next-recent-task", title: "下一个最近访问的聊天", icon: "clock.arrow.circlepath", shortcut: "⌃⇥"),
    .init(id: "previous-tab", title: "上一个标签", icon: "arrow.left.square", shortcut: "⌃⇧⇥", alternates: ["⌘⇧[", "⌘⌥←"]),
    .init(id: "next-tab", title: "下一个标签", icon: "arrow.right.square", shortcut: "⌃⇥", alternates: ["⌘⇧]", "⌘⌥→"]),
    .init(id: "next-attention", title: "下一个需关注的任务", icon: "circle.badge.exclamationmark", shortcut: "⌘⌥A"),
    .init(id: "activity", title: "显示或隐藏活动", icon: "bell", shortcut: "⌘⌥U"),
    .init(id: "clear-unread", title: "清除全部未读标记", icon: "checkmark.circle", shortcut: "⇧⎋"),
    .init(id: "back", title: "返回", icon: "arrow.left", shortcut: "⌘["),
    .init(id: "forward", title: "前进", icon: "arrow.right", shortcut: "⌘]"),
    .init(
      id: "bottom-panel", title: "切换底部面板", icon: "rectangle.bottomthird.inset.filled",
      shortcut: "⌘J"),
    .init(id: "model", title: "选择模型与推理强度", icon: "cpu", shortcut: "⌃⇧M"),
    .init(id: "reasoning-increase", title: "提高推理强度", icon: "arrow.up", shortcut: ""),
    .init(id: "reasoning-decrease", title: "降低推理强度", icon: "arrow.down", shortcut: ""),
    .init(id: "reasoning-cycle", title: "循环切换推理强度", icon: "arrow.triangle.2.circlepath", shortcut: ""),
    .init(id: "plan", title: "切换计划模式", icon: "list.bullet.clipboard", shortcut: ""),
    .init(id: "clear-prompt", title: "清除提示", icon: "eraser", shortcut: ""),
    .init(id: "add-photos", title: "添加照片…", icon: "photo", shortcut: ""),
    .init(id: "capture-appshot", title: "截取应用窗口…", icon: "camera.viewfinder", shortcut: ""),
    .init(id: "add-files", title: "附加文件与文件夹…", icon: "paperclip", shortcut: ""),
    .init(id: "dictation", title: "开始或结束听写", icon: "mic", shortcut: "⌃⇧D"),
    .init(id: "globalDictationHold", title: "按住听写", icon: "mic", shortcut: ""),
    .init(id: "globalDictationSingleTap", title: "单击听写", icon: "mic", shortcut: ""),
    .init(id: "realtimeVoice", title: "语音聊天", icon: "waveform", shortcut: ""),
    .init(id: "fork", title: "分叉到新任务", icon: "arrow.triangle.branch", shortcut: ""),
    .init(id: "open-side-chat", title: "打开临时侧聊", icon: "bubble.left.and.bubble.right", shortcut: "⌘⌥S"),
    .init(id: "open-task-window", title: "在新窗口中打开任务", icon: "macwindow.on.rectangle", shortcut: ""),
    .init(id: "copy-task-link", title: "复制任务链接", icon: "link", shortcut: "⌘⌥L"),
    .init(id: "copy-session-id", title: "复制会话 ID", icon: "number", shortcut: "⌘⌥C"),
    .init(id: "copy-conversation-path", title: "复制会话记录路径", icon: "doc.on.doc", shortcut: "⌘⌥⇧C"),
    .init(id: "task-summary", title: "切换任务摘要", icon: "sidebar.trailing", shortcut: ""),
    .init(id: "status", title: "查看当前会话状态", icon: "info.circle", shortcut: ""),
    .init(id: "init", title: "生成项目 AGENTS.md 指南", icon: "doc.text.badge.plus", shortcut: ""),
    .init(id: "worktree", title: "在新 Git 工作树中运行", icon: "arrow.triangle.branch", shortcut: ""),
    .init(id: "local", title: "在本地项目中运行", icon: "desktopcomputer", shortcut: ""),
    .init(id: "toggle-worktree-mode", title: "切换本地／工作树", icon: "arrow.left.arrow.right", shortcut: ""),
    .init(id: "git.createBranch", title: "创建分支", icon: "arrow.triangle.branch", shortcut: ""),
    .init(id: "git.commit", title: "提交或推送", icon: "arrow.up.doc", shortcut: ""),
    .init(id: "git.createPullRequest", title: "创建 PR", icon: "arrow.triangle.pull", shortcut: ""),
    .init(id: "git.createDraftPullRequest", title: "创建草稿 PR", icon: "doc.badge.ellipsis", shortcut: ""),
    .init(id: "git.openPullRequest", title: "在 GitHub 打开 PR", icon: "arrow.up.right.square", shortcut: ""),
    .init(id: "git.mergePullRequest", title: "合并 PR", icon: "arrow.triangle.merge", shortcut: ""),
    .init(id: "branch", title: "切换或创建分支", icon: "arrow.triangle.branch", shortcut: ""),
    .init(id: "settings", title: "设置", icon: "gearshape", shortcut: "⌘,"),
    .init(id: "pet", title: "显示或隐藏宠物", icon: "pawprint", shortcut: "⌥Space"),
    .init(id: "popout", title: "显示或隐藏弹出窗口", icon: "macwindow.on.rectangle", shortcut: ""),
    .init(id: "new", title: "新任务", icon: "square.and.pencil", shortcut: "⌘N", alternates: ["⌘⇧O"]),
    .init(id: "search", title: "搜索任务", icon: "magnifyingglass", shortcut: ""),
    .init(id: "projects", title: "项目", icon: "folder", shortcut: ""),
    .init(id: "project-picker", title: "选择项目", icon: "folder.badge.gearshape", shortcut: "⌘⌥⇧O"),
    .init(id: "plugins", title: "插件", icon: "shippingbox", shortcut: ""),
    .init(id: "mcp-status", title: "MCP 连接状态", icon: "network", shortcut: ""),
    .init(id: "open-skills", title: "打开技能", icon: "wand.and.stars", shortcut: ""),
    .init(id: "reload-skills", title: "重新加载技能", icon: "arrow.clockwise", shortcut: ""),
    .init(id: "automations", title: "自动化", icon: "clock.arrow.circlepath", shortcut: ""),
    .init(id: "open", title: "打开文件夹…", icon: "folder.badge.plus", shortcut: "⌘O"),
    .init(id: "environment-action-1", title: "运行首个环境操作", icon: "play.square", shortcut: "⌘⇧D"),
    .init(id: "environment-action-2", title: "运行环境操作 2", icon: "play.square", shortcut: ""),
    .init(id: "environment-action-3", title: "运行环境操作 3", icon: "play.square", shortcut: ""),
    .init(id: "environment-action-4", title: "运行环境操作 4", icon: "play.square", shortcut: ""),
    .init(id: "environment-action-5", title: "运行环境操作 5", icon: "play.square", shortcut: ""),
    .init(id: "environment-action-6", title: "运行环境操作 6", icon: "play.square", shortcut: ""),
    .init(id: "environment-action-7", title: "运行环境操作 7", icon: "play.square", shortcut: ""),
    .init(id: "environment-action-8", title: "运行环境操作 8", icon: "play.square", shortcut: ""),
    .init(id: "environment-action-9", title: "运行环境操作 9", icon: "play.square", shortcut: ""),
    .init(id: "files", title: "搜索文件", icon: "doc.text.magnifyingglass", shortcut: "⌘P"),
    .init(id: "tree", title: "切换文件树", icon: "sidebar.right", shortcut: "⌘⇧E"),
    .init(id: "terminal", title: "切换终端", icon: "terminal", shortcut: "⌃`"),
    .init(
      id: "review", title: "切换审查面板", icon: "point.3.connected.trianglepath.dotted", shortcut: "⌘⌥B"),
    .init(id: "review-open", title: "打开审查标签", icon: "square.stack.3d.up", shortcut: "⌃⇧G"),
    .init(id: "browser", title: "显示或隐藏浏览器标签", icon: "globe", shortcut: "⌘⇧B"),
    .init(id: "browser-new", title: "新建浏览器标签", icon: "plus", shortcut: "⌘T"),
    .init(id: "workspace-view", title: "切换完整与分栏视图", icon: "rectangle.split.2x1", shortcut: "⌘⇧F"),
    .init(id: "workspace-tabs", title: "显示或隐藏内容标签", icon: "rectangle.topthird.inset.filled", shortcut: ""),
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
    .init(id: "recent-chat-1", title: "打开最近任务 1", icon: "1.square", shortcut: "⌘⌥1"),
    .init(id: "recent-chat-2", title: "打开最近任务 2", icon: "2.square", shortcut: "⌘⌥2"),
    .init(id: "recent-chat-3", title: "打开最近任务 3", icon: "3.square", shortcut: "⌘⌥3"),
    .init(id: "recent-chat-4", title: "打开最近任务 4", icon: "4.square", shortcut: "⌘⌥4"),
    .init(id: "recent-chat-5", title: "打开最近任务 5", icon: "5.square", shortcut: "⌘⌥5"),
    .init(id: "recent-chat-6", title: "打开最近任务 6", icon: "6.square", shortcut: "⌘⌥6"),
    .init(id: "browser-address", title: "跳转到行或浏览器地址栏", icon: "link", shortcut: "⌘L"),
    .init(id: "browser-back", title: "浏览器后退", icon: "chevron.left", shortcut: "⌘←"),
    .init(id: "browser-forward", title: "浏览器前进", icon: "chevron.right", shortcut: "⌘→"),
    .init(id: "browser-reload", title: "重新加载网页", icon: "arrow.clockwise", shortcut: "⌘R"),
    .init(id: "browser-reload-origin", title: "忽略缓存重新加载网页", icon: "arrow.clockwise", shortcut: "⌘⇧R"),
    .init(id: "browser-copy", title: "复制浏览器网址", icon: "doc.on.doc", shortcut: ""),
    .init(id: "browser-comment-mode", title: "切换浏览或评论模式", icon: "scope", shortcut: ""),
    .init(id: "copy-location", title: "复制工作目录或浏览器网址", icon: "doc.on.doc", shortcut: "⌘⇧C"),
    .init(id: "browser-close", title: "关闭浏览器标签", icon: "xmark", shortcut: ""),
    .init(id: "browser-reopen", title: "重新打开关闭的浏览器标签", icon: "arrow.uturn.backward", shortcut: "⌘⇧T"),
    .init(id: "find", title: "在任务中查找", icon: "text.magnifyingglass", shortcut: "⌘F"),
    .init(id: "rename", title: "重命名任务…", icon: "pencil", shortcut: "⌘⌥R"),
    .init(id: "pin", title: "置顶 / 取消置顶任务", icon: "pin", shortcut: "⌘⌥P"),
    .init(id: "unread", title: "标记为未读", icon: "circle.fill", shortcut: "⌘⇧U"),
    .init(id: "archive", title: "归档任务", icon: "archivebox", shortcut: "⌘⇧A"),
    .init(id: "doctor", title: "检查开发环境", icon: "stethoscope", shortcut: ""),
    .init(id: "build", title: "构建 iOS 项目", icon: "hammer", shortcut: ""),
    .init(id: "stop", title: "停止执行", icon: "stop", shortcut: "⌘."),
    .init(id: "approval-approve", title: "批准当前请求", icon: "checkmark.shield", shortcut: "↵"),
    .init(id: "approval-decline", title: "拒绝当前请求", icon: "xmark.shield", shortcut: "⎋"),
  ]
}

enum DesktopCommandGroup: String, CaseIterable {
  case chat, navigation, panels, project, configure, skills, app

  var title: String {
    switch self {
    case .chat: "会话"
    case .navigation: "导航"
    case .panels: "面板"
    case .project: "项目"
    case .configure: "配置"
    case .skills: "技能"
    case .app: "应用"
    }
  }
}

extension DesktopCommand {
  var group: DesktopCommandGroup {
    if id.hasPrefix("git.") { return .project }
    if Self.environmentActionSlot(id) != nil { return .project }
    if id.hasPrefix("focus-chat-") || Self.recentChatSlot(id) != nil { return .navigation }
    if id.hasPrefix("focus-tab-") || id.hasPrefix("browser-") { return .panels }
    return switch id {
    case "new", "new-standalone", "send", "steer-prompt", "queue-prompt", "model", "reasoning-increase", "reasoning-decrease", "reasoning-cycle", "plan", "clear-prompt", "add-photos", "capture-appshot", "add-files", "dictation", "fork", "open-side-chat", "open-task-window", "copy-task-link", "copy-session-id", "copy-conversation-path", "status", "init", "local", "worktree", "toggle-worktree-mode", "find", "find-next", "find-previous",
      "rename", "pin", "unread", "archive", "stop", "approval-approve", "approval-decline": .chat
    case "previous-task", "next-task", "previous-tab", "next-tab", "previous-recent-task", "next-recent-task", "next-attention", "activity", "clear-unread", "back", "forward",
      "search", "sidebar": .navigation
    case "bottom-panel", "task-summary", "files", "tree", "terminal", "review", "review-open", "browser",
      "workspace-view", "workspace-tabs", "workspace-swap-panes", "tab-close", "tab-close-others": .panels
    case "projects", "project-picker", "open", "branch", "environment-action-1", "doctor", "build", "copy-location": .project
    case "theme", "settings", "shortcuts", "plugins", "mcp-status", "automations": .configure
    case "open-skills", "reload-skills": .skills
    default: .app
    }
  }
}

enum SettingsPage: String, CaseIterable, Identifiable {
  case general, profile, appearance, pets, personalization, memories, model, agent, git, codeReview, environments, usage, shortcuts, notifications, voice, browser, computerUse, appshots, connections, mcpServers, hooks, plugins, skills, worktrees, archived, runtime
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
    case .voice: "语音"
    case .browser: "浏览器"
    case .computerUse: "电脑使用"
    case .appshots: "应用快照"
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
    case .voice: "waveform"
    case .browser: "globe"
    case .computerUse: "macbook.and.iphone"
    case .appshots: "camera.viewfinder"
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
  var draftOwner: String? = nil
}
