import SwiftUI

struct WorktreeCreationView: View {
  @Bindable var store: WorkspaceStore
  let root: URL
  @State private var catalog = GitBranchCatalog()
  @State private var title = ""
  @State private var reference = ""
  @State private var refresh = UUID()
  @State private var pendingID: UUID?
  @FocusState private var naming: Bool

  private var hasStartingCommit: Bool {
    guard let snapshot = catalog.snapshot else { return false }
    return reference.isEmpty ? snapshot.currentCommit != nil
      : snapshot.branches.contains { $0.reference == reference }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Text("创建永久工作树").appFont(.title2, weight: .semibold)
        Spacer()
        Button { refresh = UUID(); reference = "" } label: { Image(systemName: "arrow.clockwise") }
          .buttonStyle(.plain).disabled(catalog.loading || store.busy || pendingID != nil).accessibilityLabel("刷新起始分支")
      }
      Text(store.library.projectTitle(root.path)).appFont(.headline)
      TextField("新项目名称", text: $title).textFieldStyle(.roundedBorder).focused($naming)
        .disabled(store.busy || pendingID != nil)
      if catalog.loading {
        ProgressView("正在读取仓库…").controlSize(.small)
      } else if let snapshot = catalog.snapshot {
        Picker("起始分支", selection: $reference) {
          Text("当前提交 · \(snapshot.currentName)").tag("")
          ForEach(snapshot.branches) { branch in Text(branch.name).tag(branch.reference) }
        }.disabled(store.busy || pendingID != nil)
        if !hasStartingCommit {
          Text("请选择已有提交的分支，或先完成首次提交。").foregroundStyle(.secondary)
        }
        if snapshot.changedFiles > 0 {
          Text("原项目有 \(snapshot.changedFiles) 个未提交文件。这些修改会留在原项目；新工作树从选定提交创建。")
            .appFont(.callout).foregroundStyle(.secondary)
        }
      }
      Text("新工作树将作为独立项目出现在侧栏，可开始多个任务。归档任务不会删除这个工作树。")
        .appFont(.callout).foregroundStyle(.secondary)
      if pendingID != nil {
        Text("创建尚未完成。继续时使用原来的位置和起始提交，不会再创建另一份工作树。")
          .appFont(.callout).foregroundStyle(.secondary)
      }
      VStack(alignment: .leading, spacing: 5) {
        Text("创建位置").appFont(.caption).foregroundStyle(.secondary)
        Text(store.worktreeRoot.path).appFont(.caption).textSelection(.enabled).lineLimit(3)
        Button("工作树设置…") { store.openSettings(.worktrees) }.buttonStyle(.plain).disabled(store.busy)
      }
      if let error = store.worktreeError ?? catalog.error {
        ScrollView { Text(error).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
          .frame(maxHeight: 100).foregroundStyle(.red).appFont(.callout)
        if store.library.permanentWorktrees.contains(where: { !$0.ready && $0.source == GitBranchService.canonicalRoot(root).path }) {
          Button("查看待恢复的工作树") { store.openSettings(.worktrees) }.disabled(store.busy)
        }
      }
      HStack {
        if store.busy { ProgressView("正在创建工作树…").controlSize(.small) }
        Spacer()
        Button("取消") { store.presentedOverlay = nil }.keyboardShortcut(.cancelAction).disabled(store.busy)
        Button(pendingID == nil ? "创建并打开" : "继续创建并打开") { create() }.keyboardShortcut(.defaultAction)
          .disabled(store.busy || (pendingID == nil && (catalog.loading || !hasStartingCommit
            || catalog.snapshot?.canChange != true || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)))
      }
    }.padding(24).frame(width: 480).interactiveDismissDisabled(store.busy)
      .onAppear { title = store.library.projectTitle(root.path) + " 工作树"; naming = true }
      .task(id: "\(root.path)|\(refresh)") { await catalog.load(root: root) }
  }

  private func create() {
    guard let snapshot = catalog.snapshot else { return }
    let branch = snapshot.branches.first { $0.reference == reference }
    Task {
      let existing = Set(store.library.permanentWorktrees.map(\.id))
      let record: PermanentWorktree?
      if let pendingID { record = await store.recoverWorktree(pendingID) }
      else { record = await store.createPermanentWorktree(snapshot: snapshot, branch: branch, title: title) }
      if let record,
        store.presentedOverlay == .worktreeCreation, store.worktreeSource == root.path {
        await store.openPermanentWorktree(record)
      } else if record == nil {
        pendingID = pendingID ?? store.library.permanentWorktrees.first { !existing.contains($0.id) && !$0.ready }?.id
      }
    }
  }
}
