import SwiftUI

struct WorktreeSettingsView: View {
  @Bindable var store: WorkspaceStore
  @FocusState private var environmentFocused: Bool?

  var body: some View {
    SettingsForm {
      HStack(spacing: 12) {
        Text("常规").padding(.horizontal, 8).padding(.vertical, 3)
          .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
          .accessibilityAddTraits(.isSelected)
        Button("环境") { store.requestSettingsPage(.environments) }
          .buttonStyle(.plain)
          .settingsActionFocus($environmentFocused, equals: true,
            activate: { store.requestSettingsPage(.environments) })
      }
      SettingsSection("工作树") {
        Text(store.worktreeRoot.path).textSelection(.enabled)
          .id(store.worktreeRoot.path)
          .settingsSearchTarget(.worktreeRoot)
        HStack {
          Button("选择文件夹…") { store.chooseWorktreeRoot() }
          Button("恢复默认目录") { store.setWorktreeRoot(nil) }.disabled(store.library.worktreeRoot == nil)
        }.disabled(store.busy)
        Text("目录设置仅用于之后创建的工作树，不会移动已有项目。")
          .appFont(.caption).foregroundStyle(.secondary)
        SettingsToggle(title: "自动删除旧工作树",
          description: "清理前保存可恢复快照；置顶或运行中的任务不会自动清理。", isOn: Binding(
          get: { store.library.automaticallyDeleteManagedWorktrees },
          set: { store.setAutomaticManagedWorktreeDeletion($0) }))
          .disabled(store.busy).settingsSearchTarget(.worktreeCleanup)
        if store.library.automaticallyDeleteManagedWorktrees {
          let limit = Binding(
            get: { store.library.managedWorktreeLimit },
            set: { store.setManagedWorktreeLimit($0) })
          LabeledContent {
            HStack(spacing: 8) {
              TextField("数量", value: limit, format: .number)
                .frame(width: 96).accessibilityLabel("托管工作树保留数量")
              Stepper("调整保留数量", value: limit, in: 1...Int.max).labelsHidden()
            }
          } label: {
            SettingsControlLabel(title: "自动删除限制",
              description: "要保留的托管工作树数量；超出时清理可安全归档的较旧工作树。")
          }.disabled(store.busy)
        }
        Text("当前有 \(store.managedWorktreeCount) 个托管工作树。清理前保存快照；置顶或运行中的任务不会自动清理。")
          .appFont(.caption).foregroundStyle(.secondary)
      }
      if store.managedWorktreeCount == 0 {
        SettingsSection("尚无托管工作树") {
          Text("此应用创建的托管工作树将显示在任务中。")
            .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 40)
        }
      }
      SettingsSection("永久工作树") {
        Text("从侧栏项目菜单创建。每个工作树是独立项目，归档其中的任务不会删除目录。").settingsSearchTarget(.worktreeList)
          .foregroundStyle(.secondary)
        if store.library.permanentWorktrees.isEmpty {
          Text("尚未创建工作树").foregroundStyle(.secondary)
        }
        ForEach(store.library.permanentWorktrees.sorted { $0.createdAt > $1.createdAt }) { record in
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Label(store.library.projectNames[record.path] ?? record.title, systemImage: "arrow.triangle.branch")
              Spacer()
              Text(record.ready ? "永久" : "待恢复").appFont(.caption).foregroundStyle(.secondary)
            }
            Text(record.path).appFont(.caption).textSelection(.enabled)
            Text("来源：\(store.library.projectTitle(record.source)) · \(record.startingName)")
              .appFont(.caption).foregroundStyle(.secondary)
            HStack {
              if record.ready {
                Button("打开项目") { Task { await store.openPermanentWorktree(record) } }
                  .disabled(store.busy || store.activeLocalRun != nil)
              } else {
                Button("继续创建 / 恢复登记") { Task { await store.recoverWorktree(record.id) } }
                  .disabled(store.busy || store.activeLocalRun != nil)
              }
              Button("在 Finder 中显示") { NSWorkspace.shared.selectFile(record.path, inFileViewerRootedAtPath: "") }
            }
          }.padding(.vertical, 5)
        }
      }
      let pendingForks = store.library.managedWorktrees.filter { $0.pendingForkSourceTaskID != nil }
      if !pendingForks.isEmpty {
        SettingsSection("待完成的分叉工作树") {
          ForEach(pendingForks) { record in
            VStack(alignment: .leading, spacing: 8) {
              Text(store.library.tasks.first(where: { $0.id == record.taskID })?.title ?? record.checkout.title)
              Text(record.path).appFont(.caption).textSelection(.enabled)
              Button("继续创建 / 初始化") { Task { await store.resumeWorktreeFork(record.taskID) } }
                .disabled(store.busy || store.managedTaskPreparing || store.activeLocalRun != nil)
            }
          }
        }
      }
      if store.busy { ProgressView("正在处理…").controlSize(.small) }
      if let error = store.worktreeError {
        SettingsSection { Text(error).foregroundStyle(.red).textSelection(.enabled) }
      }
    }.settingsFormStyle().appSurface()
  }
}
