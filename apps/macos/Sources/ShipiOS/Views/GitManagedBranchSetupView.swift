import SwiftUI

struct GitManagedBranchSetupView: View {
  @Bindable var store: WorkspaceStore
  @Bindable var workspace: DeveloperWorkspace
  let request: GitManagedBranchRequest
  @FocusState private var focused: Bool
  private var setup: GitManagedBranchSetup { workspace.managedBranchSetup }

  var body: some View {
    @Bindable var setup = setup
    VStack(alignment: .leading, spacing: 16) {
      Image(systemName: "arrow.triangle.branch").appFont(.title2)
      HStack {
        Text("在这里工作").appFont(.headline)
        Spacer()
        Button { workspace.showingManagedBranchSetup = false } label: { Image(systemName: "xmark") }
          .buttonStyle(.plain).accessibilityLabel("关闭分支准备").disabled(setup.working)
      }
      Text("创建分支，以便从此工作树提交变更、推送并创建 PR。")
        .appFont(.callout).foregroundStyle(.secondary)
      Link("了解更多", destination: URL(string: "https://developers.openai.com/codex/app/worktrees#option-1-working-on-the-worktree")!)
        .appFont(.callout)
      TextField("创建新分支", text: $setup.name).textFieldStyle(.roundedBorder)
        .focused($focused).accessibilityLabel("分支名称")
        .onSubmit { create() }.disabled(setup.loading || setup.working)
      if setup.loading { ProgressView("读取工作树…").controlSize(.small) }
      if let error = setup.validationError ?? setup.error {
        ScrollView { Text(error).appFont(.caption).foregroundStyle(.red).textSelection(.enabled) }
          .frame(maxHeight: 100)
      }
      HStack {
        if setup.error != nil {
          Button("重新检查") { Task { await load() } }.disabled(setup.working || setup.loading)
        }
        Spacer()
        if setup.working { ProgressView().controlSize(.small) }
        Button("创建", action: create).disabled(!setup.canCreate)
      }
    }.padding(20).frame(width: 380)
      .interactiveDismissDisabled(setup.working)
      .task(id: request.id) { await load() }
      .task(id: setup.name) { await setup.validate() }
      .onExitCommand { if !setup.working { workspace.showingManagedBranchSetup = false } }
  }
  private func create() {
    guard setup.canCreate else { return }
    Task { await setup.create(in: workspace, store: store) }
  }
  private func load() async {
    let suggestion = setup.request?.id == request.id ? setup.name
      : GitBranchSuggestion.name(prefix: store.library.gitPreferences.branchPrefix,
        title: store.gitCommitTaskTitle(taskID: request.taskID))
    await setup.load(request, suggestion: suggestion)
    focused = true
    await setup.validate()
  }
}
