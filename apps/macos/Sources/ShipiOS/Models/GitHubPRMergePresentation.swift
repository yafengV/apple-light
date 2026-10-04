import Foundation

/// Side-panel actions use one secondary trigger; unavailable merge can still offer auto-merge.
struct GitHubPRMergePresentation {
  enum Selection: Hashable { case confirm, enableAuto, disableAuto }
  enum Mode: Equatable { case hidden, progress(String), disableAuto, disabled(String), menu }
  enum Action: Equatable { case confirm, apply(GitHubPRMergeAction) }
  let mode: Mode
  let mergeReason: String?
  let autoReason: String?

  init(snapshot: GitHubPRMergeSnapshot?, action: GitHubPRMergeAction?, mergeReason: String?, autoReason: String?) {
    self.mergeReason = mergeReason; self.autoReason = autoReason
    guard let snapshot, snapshot.showsActions else { mode = .hidden; return }
    if let action { mode = .progress(action.progressLabel) }
    else if snapshot.isAutoMergeEnabled { mode = .disableAuto }
    else if snapshot.details.isDraft { mode = .disabled("请先将草稿标记为可供审查。") }
    else if let mergeReason, autoReason != nil { mode = .disabled(mergeReason) }
    else { mode = .menu }
  }

  var items: [SettingsDropdownItem<Selection>] {
    guard mode == .menu else { return [] }
    return [
      .option(.init(value: .confirm, title: "合并", help: mergeReason, enabled: mergeReason == nil)),
      .option(.init(value: .enableAuto, title: "启用自动合并", help: autoReason, enabled: autoReason == nil))
    ]
  }

  func action(for selection: Selection, method: GitHubPRMergeMethod) -> Action? {
    switch selection {
    case .confirm: mode == .menu && mergeReason == nil ? .confirm : nil
    case .enableAuto: mode == .menu && autoReason == nil ? .apply(.autoMerge(enabled: true, method: method)) : nil
    case .disableAuto: mode == .disableAuto && autoReason == nil ? .apply(.autoMerge(enabled: false, method: method)) : nil
    }
  }
}
