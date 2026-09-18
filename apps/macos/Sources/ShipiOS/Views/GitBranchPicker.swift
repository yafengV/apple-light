import SwiftUI

struct GitBranchPicker: View {
  @Bindable var store: WorkspaceStore
  let root: URL
  @State private var catalog = GitBranchCatalog()
  @State private var query = ""
  @State private var highlighted: String?
  @State private var creating = false
  @State private var source: GitBranchChoice?
  @State private var branchName = ""
  @State private var refresh = UUID()
  @FocusState private var focus: Field?
  private enum Field { case search, name }

  private var choices: [GitBranchChoice] {
    (catalog.snapshot?.branches ?? []).filter {
      query.isEmpty || $0.name.localizedStandardContains(query)
    }
  }
  private var selectable: [GitBranchChoice] {
    choices.filter { catalog.snapshot?.isOccupied($0) != true }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(creating ? "创建分支" : "切换分支").appFont(.headline)
        Spacer()
        Button {
          creating = false
          store.branchChangeError = nil
          refresh = UUID()
        } label: { Image(systemName: "arrow.clockwise") }
          .buttonStyle(.plain).accessibilityLabel("刷新分支列表")
          .disabled(catalog.loading || store.busy)
      }
      if catalog.loading {
        ProgressView("正在读取分支…").controlSize(.small)
      } else if let snapshot = catalog.snapshot {
        Text("当前：\(snapshot.currentName)").foregroundStyle(.secondary).lineLimit(2)
        if !snapshot.canChange {
          Text("请打开仓库根目录以切换分支：\(snapshot.repositoryRoot.path)")
            .textSelection(.enabled)
        } else if creating {
          creationForm(snapshot)
        } else {
          branchList(snapshot)
        }
        if snapshot.changedFiles > 0 {
          Text("有 \(snapshot.changedFiles) 个未提交文件。可兼容的修改会保留；有冲突时 Git 会拒绝切换。")
            .appFont(.caption).foregroundStyle(.secondary)
        }
      }
      if let error = store.branchChangeError ?? catalog.error {
        ScrollView { Text(error).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
          .frame(maxHeight: 100).appFont(.caption).foregroundStyle(.red)
      }
      if store.busy { ProgressView("正在更新工作区…").controlSize(.small) }
      HStack {
        Spacer()
        Button("关闭") { store.showingBranchPicker = false }
      }
    }
    .padding(16).frame(width: 360).appFont(.callout)
    .task(id: "\(root.path)|\(refresh)") { await catalog.load(root: root) }
    .onChange(of: choices) { _, choices in
      if !choices.contains(where: { $0.id == highlighted }) { highlighted = selectable.first?.id }
    }
    .onExitCommand {
      if creating && !store.busy { focus = nil; creating = false }
      else { store.showingBranchPicker = false }
    }
  }

  private func branchList(_ snapshot: GitBranchSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      TextField("搜索分支", text: $query).textFieldStyle(.roundedBorder).focused($focus, equals: .search)
        .task { focus = .search }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onSubmit {
          if let choice = selectable.first(where: { $0.id == highlighted }) ?? selectable.first {
            choose(choice, snapshot)
          }
        }
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 2) {
            ForEach(choices) { choice in
              Button { choose(choice, snapshot) } label: {
                HStack {
                  Image(systemName: choice.isRemote ? "network" : "arrow.triangle.branch")
                  VStack(alignment: .leading, spacing: 2) {
                    Text(choice.name).lineLimit(2)
                    if snapshot.isOccupied(choice) {
                      Text("其他工作树正在使用").appFont(.caption).foregroundStyle(.secondary)
                    } else if choice.isRemote {
                      Text("远程分支 · 创建本地跟踪分支").appFont(.caption).foregroundStyle(.secondary)
                    }
                  }
                  Spacer()
                  if choice.reference == snapshot.currentReference {
                    Image(systemName: "checkmark").accessibilityLabel("当前分支")
                  }
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                  .contentShape(Rectangle()).background(
                    highlighted == choice.id ? Color.primary.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
              }.buttonStyle(.plain).disabled(snapshot.isOccupied(choice))
                .help(choice.checkedOutPath ?? choice.reference).id(choice.id)
            }
            if choices.isEmpty { Text("没有匹配的分支").foregroundStyle(.secondary).padding(8) }
          }
        }.frame(height: 220)
          .onChange(of: highlighted) { _, id in if let id { proxy.scrollTo(id) } }
      }
      Divider()
      Button("从当前提交创建分支…") {
        source = nil; branchName = store.library.gitPreferences.branchPrefix; focus = nil; creating = true
        store.branchChangeError = nil
      }.disabled(snapshot.currentCommit == nil)
      if snapshot.currentCommit == nil {
        Text("完成首次提交后可创建分支。").appFont(.caption).foregroundStyle(.secondary)
      }
    }.disabled(store.busy)
  }

  private func creationForm(_ snapshot: GitBranchSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("起点：\(source?.name ?? snapshot.currentName)").foregroundStyle(.secondary)
      TextField("本地分支名称", text: $branchName).textFieldStyle(.roundedBorder)
        .focused($focus, equals: .name).onSubmit { create(snapshot) }
        .task { focus = .name }
      HStack {
        Button("返回列表") { focus = nil; creating = false; store.branchChangeError = nil }
        Spacer()
        Button("创建并切换") { create(snapshot) }
          .disabled(branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }.disabled(store.busy)
  }

  private func choose(_ choice: GitBranchChoice, _ snapshot: GitBranchSnapshot) {
    guard !store.busy, !snapshot.isOccupied(choice) else { return }
    if choice.isRemote {
      source = choice; branchName = choice.suggestedLocalName; focus = nil; creating = true
      store.branchChangeError = nil
    } else {
      Task { await store.changeBranch(.switchTo(choice), snapshot: snapshot) }
    }
  }
  private func create(_ snapshot: GitBranchSnapshot) {
    guard !branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !store.busy else { return }
    let change = GitBranchChange.create(name: branchName, startingAt: source)
    Task { await store.changeBranch(change, snapshot: snapshot) }
  }
  private func move(_ offset: Int) {
    guard !selectable.isEmpty else { return }
    let index = selectable.firstIndex(where: { $0.id == highlighted }) ?? (offset > 0 ? -1 : 0)
    highlighted = selectable[(index + offset + selectable.count) % selectable.count].id
  }
}
