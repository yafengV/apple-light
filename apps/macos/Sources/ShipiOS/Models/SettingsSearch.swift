import Foundation

enum BrowserSettingsSection: String, CaseIterable, Identifiable {
  case history = "历史与数据"
  case downloads = "下载"
  case permissions = "权限"
  var id: String { rawValue }
}

enum ConnectionSettingsSection: String, CaseIterable, Identifiable {
  case thisMac, devices, ssh
  var id: String { rawValue }
  var title: String {
    switch self { case .thisMac: "控制此 Mac"; case .devices: "控制其他设备"; case .ssh: "SSH" }
  }
}

enum SettingsSearchField: String, CaseIterable, Identifiable {
  case editor, tips, sendShortcut, plainText, contextUsage, bottomPanel, webLinks,
    projectlessFolder, popoutScope, followUp, menuBar, reviewDelivery, terminalLocation,
    preventSleep, enablePlugins
  case theme, lightPalette, darkPalette, uiFont, uiFontSize, codeFont, codeFontSize,
    pointer, diffMarkers, reduceMotion, importTheme, exportTheme
  case apiURL, modelID, apiKey, reasoning, tokenUsage

  case profileName
  case profileUsername
  case profileAvatar
  case profileCard
  case replyStyle
  case suggestions
  case instructions
  case memoryEnabled
  case memoryAdd
  case memorySaved
  case notificationTiming
  case notificationPrompt
  case notificationPermission
  case notificationTest
  case petChoice
  case petVisibility
  case petSize
  case petImport
  case agentModel
  case agentReasoning
  case agentSuggestions
  case branchPrefix
  case commitInstructions
  case pullRequestInstructions
  case alwaysForcePush
  case createDraftPullRequests
  case gitWorktreeRoot
  case reviewScope
  case readOnlyReview
  case environmentContainer
  case environmentScheme
  case environmentConfiguration
  case worktreeRoot
  case worktreeList
  case anyApplication
  case screenRecording
  case accessibility
  case allowedApplications
  case browserHistory
  case browserClear
  case browserDownloadFolder
  case browserAskDownload
  case browserDownloadHistory
  case browserDefaultAccess
  case browserAddRule
  case connectionThisMac
  case connectionDevices
  case connectionSSH
  case shortcutSearch
  case shortcutNumbers
  case shortcutExternalBrowser
  case shortcutReset
  case archivedSearch
  case archivedDeleteAll
  case usagePeriod
  case usageTokens
  case usageRecent
  case usageTopTasks
  case runtimeAgent
  case runtimeRoot
  case mcpImport
  case mcpInstalled
  case hooksImport
  case hooksInstalled
  case pluginsImport
  case pluginsInstalled
  case skillsImport
  case skillsInstalled

  var id: String { "setting:" + rawValue }
  var requiresProject: Bool {
    [.environmentContainer, .environmentScheme, .environmentConfiguration].contains(self)
  }
  var browserSection: BrowserSettingsSection? {
    switch self {
    case .browserHistory, .browserClear: .history
    case .browserDownloadFolder, .browserAskDownload, .browserDownloadHistory: .downloads
    case .browserDefaultAccess, .browserAddRule: .permissions
    default: nil
    }
  }
  var connectionSection: ConnectionSettingsSection? {
    switch self {
    case .connectionThisMac: .thisMac
    case .connectionDevices: .devices
    case .connectionSSH: .ssh
    default: nil
    }
  }
  var page: SettingsPage {
    switch self {
    case .theme, .lightPalette, .darkPalette, .uiFont, .uiFontSize, .codeFont, .codeFontSize,
      .pointer, .diffMarkers, .reduceMotion, .importTheme, .exportTheme: .appearance
    case .apiURL, .modelID, .apiKey, .reasoning, .tokenUsage: .model
    case .profileName: .profile
    case .profileUsername: .profile
    case .profileAvatar: .profile
    case .profileCard: .profile
    case .replyStyle: .personalization
    case .suggestions: .personalization
    case .instructions: .personalization
    case .memoryEnabled: .memories
    case .memoryAdd: .memories
    case .memorySaved: .memories
    case .notificationTiming: .notifications
    case .notificationPrompt: .notifications
    case .notificationPermission: .notifications
    case .notificationTest: .notifications
    case .petChoice: .pets
    case .petVisibility: .pets
    case .petSize: .pets
    case .petImport: .pets
    case .agentModel: .agent
    case .agentReasoning: .agent
    case .agentSuggestions: .agent
    case .branchPrefix: .git
    case .commitInstructions: .git
    case .pullRequestInstructions: .git
    case .alwaysForcePush: .git
    case .createDraftPullRequests: .git
    case .gitWorktreeRoot: .git
    case .reviewScope: .codeReview
    case .readOnlyReview: .codeReview
    case .environmentContainer: .environments
    case .environmentScheme: .environments
    case .environmentConfiguration: .environments
    case .worktreeRoot: .worktrees
    case .worktreeList: .worktrees
    case .anyApplication: .computerUse
    case .screenRecording: .computerUse
    case .accessibility: .computerUse
    case .allowedApplications: .computerUse
    case .browserHistory: .browser
    case .browserClear: .browser
    case .browserDownloadFolder: .browser
    case .browserAskDownload: .browser
    case .browserDownloadHistory: .browser
    case .browserDefaultAccess: .browser
    case .browserAddRule: .browser
    case .connectionThisMac: .connections
    case .connectionDevices: .connections
    case .connectionSSH: .connections
    case .shortcutSearch: .shortcuts
    case .shortcutNumbers: .shortcuts
    case .shortcutExternalBrowser: .shortcuts
    case .shortcutReset: .shortcuts
    case .archivedSearch: .archived
    case .archivedDeleteAll: .archived
    case .usagePeriod: .usage
    case .usageTokens: .usage
    case .usageRecent: .usage
    case .usageTopTasks: .usage
    case .runtimeAgent: .runtime
    case .runtimeRoot: .runtime
    case .mcpImport: .plugins
    case .mcpInstalled: .plugins
    case .hooksImport: .hooks
    case .hooksInstalled: .hooks
    case .pluginsImport: .plugins
    case .pluginsInstalled: .plugins
    case .skillsImport: .plugins
    case .skillsInstalled: .plugins
    default: .general
    }
  }
  var title: String {
    switch self {
    case .profileName: "显示名称"
    case .profileUsername: "用户名"
    case .profileAvatar: "选择头像"
    case .profileCard: "保存资料卡"
    case .replyStyle: "默认回复风格"
    case .suggestions: "显示建议提示"
    case .instructions: "自定义指令"
    case .memoryEnabled: "启用记忆"
    case .memoryAdd: "添加记忆"
    case .memorySaved: "已保存的记忆"
    case .notificationTiming: "显示通知"
    case .notificationPrompt: "需要通知时询问系统权限"
    case .notificationPermission: "通知权限"
    case .notificationTest: "发送测试通知"
    case .petChoice: "选择宠物"
    case .petVisibility: "显示或隐藏宠物"
    case .petSize: "宠物大小"
    case .petImport: "导入宠物"
    case .agentModel: "默认模型"
    case .agentReasoning: "推理强度"
    case .agentSuggestions: "显示建议提示"
    case .branchPrefix: "分支前缀"
    case .commitInstructions: "提交指令"
    case .pullRequestInstructions: "PR 指令"
    case .alwaysForcePush: "始终强制推送"
    case .createDraftPullRequests: "创建草稿 PR"
    case .gitWorktreeRoot: "工作树根目录"
    case .reviewScope: "默认变更范围"
    case .readOnlyReview: "只读审查"
    case .environmentContainer: "容器"
    case .environmentScheme: "Scheme"
    case .environmentConfiguration: "构建配置"
    case .worktreeRoot: "工作树根目录"
    case .worktreeList: "永久工作树"
    case .anyApplication: "任意应用"
    case .screenRecording: "屏幕录制"
    case .accessibility: "辅助功能"
    case .allowedApplications: "始终允许的应用"
    case .browserHistory: "浏览历史"
    case .browserClear: "清除浏览数据"
    case .browserDownloadFolder: "下载位置"
    case .browserAskDownload: "每次下载时询问保存位置"
    case .browserDownloadHistory: "下载记录"
    case .browserDefaultAccess: "默认网站访问"
    case .browserAddRule: "添加网站规则"
    case .connectionThisMac: "控制此 Mac"
    case .connectionDevices: "控制其他设备"
    case .connectionSSH: "SSH 主机"
    case .shortcutSearch: "搜索命令与组合键"
    case .shortcutNumbers: "数字快捷键"
    case .shortcutExternalBrowser: "在默认浏览器中打开网页链接"
    case .shortcutReset: "恢复全部默认"
    case .archivedSearch: "搜索已归档任务"
    case .archivedDeleteAll: "全部删除归档任务"
    case .usagePeriod: "时间范围"
    case .usageTokens: "Token 用量"
    case .usageRecent: "最近会话"
    case .usageTopTasks: "高用量任务"
    case .runtimeAgent: "Agent 连接"
    case .runtimeRoot: "数据根目录"
    case .mcpImport: "添加 MCP 服务器"
    case .mcpInstalled: "已安装 MCP 服务器"
    case .hooksImport: "导入本地插件"
    case .hooksInstalled: "已安装 Hooks"
    case .pluginsImport: "导入本地插件"
    case .pluginsInstalled: "已安装插件"
    case .skillsImport: "导入本地技能"
    case .skillsInstalled: "已安装技能"
    case .editor: "默认编辑器"
    case .tips: "显示教育提示"
    case .sendShortcut: "发送快捷键"
    case .plainText: "纯文本编辑器"
    case .contextUsage: "显示上下文窗口用量"
    case .bottomPanel: "底部面板"
    case .webLinks: "打开网页链接"
    case .projectlessFolder: "无项目任务文件夹"
    case .popoutScope: "弹出窗口默认从项目外开始"
    case .followUp: "模型运行时发送消息"
    case .menuBar: "在菜单栏中显示"
    case .reviewDelivery: "审查结果呈现方式"
    case .terminalLocation: "默认终端位置"
    case .preventSleep: "运行时防止休眠"
    case .enablePlugins: "插件"
    case .theme: "基础主题"
    case .lightPalette: "浅色主题颜色、侧栏透明度与对比度"
    case .darkPalette: "深色主题颜色、侧栏透明度与对比度"
    case .uiFont: "界面字体"
    case .uiFontSize: "界面字号"
    case .codeFont: "代码字体"
    case .codeFontSize: "代码字号"
    case .pointer: "交互控件使用指针光标"
    case .diffMarkers: "差异标记"
    case .reduceMotion: "减少动态效果"
    case .importTheme: "导入主题"
    case .exportTheme: "导出主题"
    case .apiURL: "基础地址"
    case .modelID: "模型 ID"
    case .apiKey: "API Key"
    case .reasoning: "推理强度"
    case .tokenUsage: "记录服务返回的 token 用量"
    }
  }
  var aliases: String {
    switch self {
    case .profileName: "名称"
    case .profileUsername: "username"
    case .profileAvatar: "avatar"
    case .profileCard: "PNG"
    case .replyStyle: "回复风格"
    case .suggestions: "新任务建议"
    case .instructions: "个人指令"
    case .memoryEnabled: "memory"
    case .memoryAdd: "新记忆"
    case .memorySaved: "编辑 删除 清空"
    case .notificationTiming: "任务结束 提醒时机"
    case .notificationPrompt: "权限"
    case .notificationPermission: "允许通知"
    case .notificationTest: "测试"
    case .petChoice: "Codey Mini"
    case .petVisibility: "浮动宠物"
    case .petSize: "缩放"
    case .petImport: "自定义 PNG WebP"
    case .agentModel: "配置"
    case .agentReasoning: "配置"
    case .agentSuggestions: "建议"
    case .branchPrefix: "branch"
    case .commitInstructions: "commit message instructions 提交说明 生成"
    case .pullRequestInstructions: "pull request instructions GitHub 描述 生成"
    case .alwaysForcePush: "push force-with-lease 远端"
    case .createDraftPullRequests: "draft pull request GitHub"
    case .gitWorktreeRoot: "目录"
    case .reviewScope: "比较范围"
    case .readOnlyReview: "暂存 提交"
    case .environmentContainer: "xcodeproj xcworkspace"
    case .environmentScheme: "方案"
    case .environmentConfiguration: "Debug Release"
    case .worktreeRoot: "文件夹"
    case .worktreeList: "恢复登记"
    case .anyApplication: "控制"
    case .screenRecording: "系统访问"
    case .accessibility: "系统访问"
    case .allowedApplications: "添加应用"
    case .browserHistory: "历史与数据 搜索标题网址"
    case .browserClear: "Cookie 缓存"
    case .browserDownloadFolder: "文件夹"
    case .browserAskDownload: "保存 下载"
    case .browserDownloadHistory: "清除已完成记录"
    case .browserDefaultAccess: "Agent 权限"
    case .browserAddRule: "访问权限"
    case .connectionThisMac: "本地设备"
    case .connectionDevices: "远程设备"
    case .connectionSSH: "重新扫描 连接"
    case .shortcutSearch: "快捷键 键盘"
    case .shortcutNumbers: "⌘1–9 ⌃1–9 标签 聊天 Number shortcuts Tabs Chats"
    case .shortcutExternalBrowser: "网页 链接 系统浏览器 修饰键 ⌘点按 ⌥点按 ⇧⌘点按 未设置 Open web link in default browser"
    case .shortcutReset: "快捷键"
    case .archivedSearch: "项目"
    case .archivedDeleteAll: "永久删除"
    case .usagePeriod: "7天 30天"
    case .usageTokens: "输入 输出 总计"
    case .usageRecent: "模型 推理"
    case .usageTopTasks: "统计"
    case .runtimeAgent: "运行时"
    case .runtimeRoot: "运行时"
    case .mcpImport: "MCP 服务器"
    case .mcpInstalled: "启用"
    case .hooksImport: "Hooks 钩子"
    case .hooksInstalled: "启用"
    case .pluginsImport: "安装"
    case .pluginsInstalled: "启用"
    case .skillsImport: "技能"
    case .skillsInstalled: "启用"
    case .editor: "外部编辑器 Xcode Visual Studio Code"
    case .sendShortcut: "Enter Return 发送快捷键"
    case .plainText: "Markdown 富文本 plain text"
    case .projectlessFolder: "项目外任务目录 folder"
    case .followUp: "追加消息 引导当前运行 等待下一轮"
    case .menuBar: "menu bar"
    case .reviewDelivery: "review 内联 单独"
    case .preventSleep: "sleep"
    case .apiURL: "API base URL 服务地址"
    case .apiKey: "API 密钥"
    case .lightPalette, .darkPalette: "强调色 背景色 前景色 半透明侧栏"
    default: rawValue
    }
  }
}

struct SettingsSearchResult: Identifiable, Equatable {
  let page: SettingsPage
  let field: SettingsSearchField?
  let commandID: String?
  init(page: SettingsPage, field: SettingsSearchField? = nil, commandID: String? = nil) {
    self.page = page
    self.field = field
    self.commandID = commandID
  }
  var id: String { commandID.map { "shortcut:" + $0 } ?? field?.id ?? "page:" + page.rawValue }
  var title: String {
    commandID.flatMap { id in DesktopCommand.all.first { $0.id == id }?.title }
      ?? field?.title ?? page.title
  }
}

struct SettingsSearchRequest: Equatable {
  let result: SettingsSearchResult
  let token = UUID()
}

enum SettingsSearch {
  static func results(
    for query: String, hasProject: Bool = false,
    shortcutBindings: [String: [ShortcutBinding]]? = nil,
    pluginSections: Set<PluginSettingsSection> = Set(PluginSettingsSection.allCases)
  ) -> [SettingsSearchResult] {
    let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
    guard !terms.isEmpty else { return [] }
    func matches(_ document: String) -> Bool {
      terms.allSatisfy { document.localizedStandardContains($0) }
    }
    return SettingsNavigation.pages.flatMap { page -> [SettingsSearchResult] in
      let fields = SettingsSearchField.allCases.filter {
        $0.page == page && (!$0.requiresProject || hasProject)
          && ($0.pluginSection.map { pluginSections.contains($0) } ?? true)
          && matches([page.title, $0.title, $0.aliases].joined(separator: " "))
      }.map { SettingsSearchResult(page: page, field: $0) }
      let commands = page == .shortcuts ? DesktopCommand.all.filter { command in
        let bindings = shortcutBindings?[command.id] ?? (shortcutBindings == nil ? command.defaultBindings : [])
        return matches([page.title, command.title, command.id, bindings.map(\.display).joined(separator: " ")]
          .joined(separator: " "))
      }.map { SettingsSearchResult(page: page, commandID: $0.id) } : []
      let pageMatches = matches(page.title + " " + page.rawValue)
      // Keep the existing page-keyword search for pages without field anchors.
      let fallback = fields.isEmpty && commands.isEmpty && SettingsNavigation.results(for: query).contains(page)
      return (pageMatches || fallback ? [SettingsSearchResult(page: page)] : []) + fields + commands
    }
  }
}

extension WorkspaceStore {
  func revealSetting(_ result: SettingsSearchResult) {
    if let section = result.field?.pluginSection {
      guard visiblePluginSettingsSections.contains(section) else { return }
    }
    if let commandID = result.commandID {
      guard result.page == .shortcuts, result.field == nil,
        DesktopCommand.all.contains(where: { $0.id == commandID }) else { return }
    }
    guard result.field == nil || result.field?.page == result.page else { return }
    guard result.field?.requiresProject != true || project != nil else { return }
    if destination != .settings { openSettings(result.page) }
    settingsPage = result.page
    if let section = result.field?.browserSection { browserSettingsSection = section }
    if let section = result.field?.connectionSection { connectionSettingsSection = section }
    if let section = result.field?.pluginSection {
      pluginSettingsQuery = ""
      pluginSettingsSection = section
    }
    settingsSearchRequest = SettingsSearchRequest(result: SettingsSearchResult(
      page: settingsPage, field: result.field, commandID: result.commandID))
  }
}
