import SwiftUI

enum GitInstructionKind {
  case commit, pullRequest
  var title: String { self == .commit ? "提交指令" : "PR 指令" }
  var subtitle: String { self == .commit ? "添加到提交说明的生成提示中。" : "添加到 PR 标题和描述的生成提示中。" }
  var field: SettingsSearchField { self == .commit ? .commitInstructions : .pullRequestInstructions }
  var keyPath: WritableKeyPath<GitPreferences, String> {
    self == .commit ? \.commitInstructions : \.pullRequestInstructions
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
      TextEditor(text: $draft).frame(minHeight: 110)
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
