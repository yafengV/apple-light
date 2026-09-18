import Foundation

enum ComposerCommand: String, CaseIterable, Identifiable {
  case chat, doctor, build, plan, goal, model, reasoning, fork, review, files, terminal, pet, plugins, automations, project, new

  var id: String { rawValue }
  var token: String { "/" + rawValue }
  var localAction: LocalAction? { LocalAction(rawValue: rawValue) }
  var actionID: String {
    switch self {
    case .project: "projects"
    case .reasoning: "model"
    default: rawValue
    }
  }
  var title: String {
    localAction?.title ?? [
      "review": "审查代码变更", "files": "搜索文件", "terminal": "切换终端",
      "project": "项目", "new": "新任务", "fork": "分叉到新任务",
      "plan": "制定实施计划",
      "goal": "定义目标与成功标准",
      "model": "选择模型", "reasoning": "选择推理强度",
      "pet": "显示或隐藏宠物",
      "plugins": "浏览插件",
      "automations": "管理自动化",
    ][rawValue] ?? rawValue
  }
}

struct ComposerCommandSelection {
  enum Key { case previous, next, accept, dismiss }
  enum Result: Equatable { case ignored, handled, accept(ComposerCommand) }

  private(set) var draft = ""
  private(set) var matches: [ComposerCommand] = []
  private(set) var selected: ComposerCommand?
  private(set) var dismissed = false
  private var enabled: Set<ComposerCommand> = []
  var isVisible: Bool { !dismissed && !matches.isEmpty }

  mutating func update(draft: String, enabled: Set<ComposerCommand>) {
    if draft != self.draft {
      dismissed = false
      selected = nil
    }
    self.draft = draft
    self.enabled = enabled
    matches = draft.hasPrefix("/") && !draft.contains(where: \.isWhitespace)
      ? ComposerCommand.allCases.filter { $0.token.hasPrefix(draft.lowercased()) } : []
    if selected == nil || !matches.contains(selected!) || !enabled.contains(selected!) {
      selected = matches.first(where: enabled.contains)
    }
  }

  mutating func highlight(_ command: ComposerCommand) {
    guard matches.contains(command), enabled.contains(command) else { return }
    selected = command
  }

  mutating func handle(_ key: Key, isComposing: Bool = false) -> Result {
    guard isVisible, !isComposing else { return .ignored }
    switch key {
    case .dismiss:
      dismissed = true
      return .handled
    case .accept:
      // A visible but unavailable command must not fall through to sending text.
      return selected.map(Result.accept) ?? .handled
    case .previous, .next:
      let choices = matches.filter(enabled.contains)
      guard !choices.isEmpty else { return .handled }
      let index = selected.flatMap { choices.firstIndex(of: $0) } ?? 0
      selected = choices[min(max(index + (key == .next ? 1 : -1), 0), choices.count - 1)]
      return .handled
    }
  }
}
