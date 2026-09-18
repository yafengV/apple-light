import Foundation

struct SettingsNavigationGroup: Identifiable {
  let id: String
  let title: String
  let pages: [SettingsPage]
}

enum SettingsNavigation {
  static let groups: [SettingsNavigationGroup] = [
    .init(id: "personal", title: "个人", pages: [
      .general, .notifications, .profile, .appearance, .agent, .personalization,
      .memories, .pets, .shortcuts, .usage, .model,
    ]),
    .init(id: "integrations", title: "集成", pages: [
      .computerUse, .plugins, .browser,
    ]),
    .init(id: "coding", title: "编码", pages: [
      .hooks, .connections, .codeReview, .git, .environments, .worktrees,
    ]),
    .init(id: "archived", title: "归档", pages: [.archived, .runtime]),
  ]

  static var pages: [SettingsPage] { groups.flatMap(\.pages) }

  static func results(for query: String) -> [SettingsPage] {
    let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
    guard !terms.isEmpty else { return pages }
    return pages.filter { page in
      let document = ([page.title, page.rawValue] + keywords(for: page)).joined(separator: " ")
      return terms.allSatisfy { document.localizedStandardContains($0) }
    }
  }

  static func adjacent(to page: SettingsPage?, offset: Int, in pages: [SettingsPage]) -> SettingsPage? {
    guard !pages.isEmpty else { return nil }
    guard let page, let index = pages.firstIndex(of: page) else {
      return offset < 0 ? pages.last : pages.first
    }
    let next = index + offset
    return pages.indices.contains(next) ? pages[next] : nil
  }

  private static func keywords(for page: SettingsPage) -> [String] {
    switch page {
    case .general: ["发送快捷键", "纯文本编辑器", "教育提示", "上下文窗口用量", "底部面板", "追加消息", "网页链接", "项目外任务文件夹", "无项目任务文件夹", "弹出窗口", "菜单栏", "审查结果呈现方式", "默认终端位置", "防止休眠", "外部编辑器"]
    case .appearance: ["主题", "浅色", "深色", "颜色", "字体", "对比度", "透明", "指针", "差异标记", "减少动态效果"]
    case .model: ["API", "模型", "服务", "密钥", "base URL", "推理"]
    case .profile: ["头像", "名称", "用户名", "活动"]
    case .personalization: ["个人指令", "回复风格", "建议提示"]
    case .memories: ["记忆", "memory"]
    case .pets: ["Codey", "Mini", "宠物", "全局快捷键"]
    case .shortcuts: ["键盘", "快捷键", "keyboard", "改键"]
    case .notifications: ["通知", "提醒", "权限"]
    case .usage: ["token", "用量", "输入", "输出"]
    case .agent: ["配置", "模型默认值", "推理强度"]
    case .git: ["分支前缀", "工作树根目录", "Git 状态"]
    case .codeReview: ["代码审查", "比较范围", "只读", "暂存", "提交"]
    case .environments: ["环境", "Scheme", "Debug", "Release", "构建配置"]
    case .worktrees: ["工作树", "Worktrees", "根目录", "恢复"]
    case .browser: ["浏览器", "历史", "网站数据", "下载", "权限"]
    case .computerUse: ["电脑使用", "屏幕录制", "辅助功能", "允许应用"]
    case .connections: ["SSH", "远程", "主机", "设备", "连接"]
    case .mcpServers: ["MCP", "服务器", "插件"]
    case .hooks: ["Hooks", "钩子", "插件"]
    case .plugins: ["插件", "安装", "导入", "启用", "MCP", "服务器", "技能", "Skills"]
    case .skills: ["技能", "Skills", "插件"]
    case .archived: ["归档", "恢复任务", "删除任务"]
    case .runtime: ["Agent", "运行时", "数据目录", "连接"]
    }
  }
}
