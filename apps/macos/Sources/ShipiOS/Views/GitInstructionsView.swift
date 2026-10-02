import SwiftUI

enum GitInstructionKind {
  case commit, pullRequest, watch
  var title: String {
    switch self {
    case .commit: "提交指令"
    case .pullRequest: "PR 指令"
    case .watch: "PR 监控指令"
    }
  }
  var subtitle: String {
    switch self {
    case .commit: "添加到提交说明的生成提示中。"
    case .pullRequest: "添加到 PR 标题和描述的生成提示中。"
    case .watch: "创建监控任务时添加到检查、修复与合并指令中。"
    }
  }
  var field: SettingsSearchField {
    switch self {
    case .commit: .commitInstructions
    case .pullRequest: .pullRequestInstructions
    case .watch: .pullRequestWatchInstructions
    }
  }
  var keyPath: WritableKeyPath<GitPreferences, String> {
    switch self {
    case .commit: \.commitInstructions
    case .pullRequest: \.pullRequestInstructions
    case .watch: \.pullRequestWatchInstructions
    }
  }
}

struct GitInstructionsView: View {
  let store: WorkspaceStore
  let kind: GitInstructionKind
  @State private var draft = ""
  @State private var saved = ""
  @State private var loaded = false
  @State private var error: String?

  var body: some View {
    Section(kind.title) {
      Text(kind.subtitle)
        .appFont(.caption).foregroundStyle(.secondary)
      SettingsTextEditor(text: $draft, label: kind.title).frame(minHeight: 110)
        .accessibilityLabel(kind.title).settingsSearchTarget(kind.field)
      HStack {
        if let error { Text(error).appFont(.caption).foregroundStyle(.red) }
        else if loaded && draft == saved {
          Label("已保存", systemImage: "checkmark").appFont(.caption).foregroundStyle(.secondary)
        } else { Text("等待保存…").appFont(.caption).foregroundStyle(.secondary) }
        Spacer()
        Button("保存") { save() }.disabled(!loaded || draft == saved)
      }
    }
    .onAppear {
      guard !loaded else { return }
      draft = store.library.gitPreferences[keyPath: kind.keyPath]
      saved = draft; loaded = true
    }
    .task(id: draft) {
      guard loaded, draft != saved else { return }
      try? await Task.sleep(for: .milliseconds(600))
      guard !Task.isCancelled else { return }
      save()
    }
    .onDisappear { if loaded && draft != saved { save() } }
    .onChange(of: store.settingsPage) { _, page in
      if page != .git, loaded && draft != saved { save() }
    }
  }
  private func save() {
    var preferences = store.library.gitPreferences
    preferences[keyPath: kind.keyPath] = draft
    if store.saveGitPreferences(preferences) { saved = draft; error = nil }
    else { error = store.error ?? "指令保存失败，请重试。" }
  }
}
