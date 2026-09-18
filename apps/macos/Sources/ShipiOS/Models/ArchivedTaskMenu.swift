import Foundation

enum ArchivedTaskMenuChoice: Hashable {
  case kind(ArchivedTaskKind), sort(ArchivedTaskSort)
}

enum ArchivedTaskMenu {
  static func filters(kind: ArchivedTaskKind, sort: ArchivedTaskSort) -> [SettingsDropdownItem<ArchivedTaskMenuChoice>] {
    [.section("类型")] + ArchivedTaskKind.allCases.map {
      .option(.init(value: .kind($0), title: $0.title, selected: kind == $0))
    } + [.separator, .section("排序依据")] + ArchivedTaskSort.allCases.map {
      .option(.init(value: .sort($0), title: $0.title, selected: sort == $0))
    }
  }

  static func projects(_ presentation: ArchivedTaskPresentation,
    selection: ArchivedProjectFilter) -> [SettingsDropdownItem<ArchivedProjectFilter>] {
    let current = presentation.effectiveFilter(selection)
    return [.option(.init(value: .all, title: "所有项目", selected: current == .all)), .separator]
      + presentation.projects.map {
        .option(.init(value: .project($0.path), title: $0.title,
          selected: current == .project($0.path), systemImage: "folder", help: $0.path))
      } + [.separator,
        .option(.init(value: .projectless, title: "无项目任务", selected: current == .projectless,
          systemImage: "bubble.left.and.bubble.right")),
        .option(.init(value: .automations, title: "计划任务", selected: current == .automations,
          systemImage: "clock"))]
  }
}
