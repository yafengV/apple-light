import SwiftUI

struct ProjectLibraryView: View {
  @Bindable var store: WorkspaceStore
  @State private var query = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Text("项目").appFont(.title2, weight: .semibold)
        Spacer()
        Button("添加文件夹…") {
          store.chooseProject()
        }
        Button("返回任务") { store.returnToWorkspace() }
          .keyboardShortcut(store.destination == .projects ? .cancelAction : nil)
      }
      TextField("搜索项目或路径", text: $query).textFieldStyle(.roundedBorder)
      List(
        store.library.orderedProjects.filter {
          query.isEmpty || store.library.projectTitle($0).localizedCaseInsensitiveContains(query)
            || $0.localizedCaseInsensitiveContains(query)
        }, id: \.self
      ) { path in
        HStack {
          Image(systemName: store.library.isPermanentWorktree(path) ? "arrow.triangle.branch" : "folder")
          VStack(alignment: .leading) {
            Text(store.library.projectTitle(path)).appFont(.headline)
            Text(path).appFont(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
          Spacer()
          Button {
            store.toggleProjectPin(path)
          } label: {
            Image(systemName: store.library.pinnedProjects.contains(path) ? "pin.fill" : "pin")
          }.buttonStyle(.plain).help(
            store.library.pinnedProjects.contains(path) ? "取消置顶项目" : "置顶项目")
          Button("打开") {
            Task {
              await store.open(URL(fileURLWithPath: path))
              if store.connected { store.returnToWorkspace() }
            }
          }.disabled(store.busy || store.activeLocalRun != nil)
          Menu {
            ProjectActionsMenu(store: store, path: path)
          } label: {
            Image(systemName: "ellipsis")
          }
          .menuStyle(.borderlessButton).fixedSize().accessibilityLabel(
            "项目菜单：\(store.library.projectTitle(path))")
        }.padding(.vertical, 8)
          .contextMenu { ProjectActionsMenu(store: store, path: path) }
      }
    }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
