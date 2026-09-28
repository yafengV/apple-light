import SwiftUI

struct GitReviewRepositoryPicker: View {
  @Bindable var workspace: DeveloperWorkspace

  var body: some View {
    HStack {
      if workspace.reviewScope == .lastTurn {
        Label("所有仓库", systemImage: "folder")
      } else {
        Picker("仓库", selection: selection) {
          ForEach(workspace.reviewRepositories) { entry in
            Text(title(entry)).help(entry.root.path).tag(entry.id)
          }
        }.pickerStyle(.menu).disabled(!workspace.canSelectReviewRepository)
          .accessibilityLabel("审查仓库")
      }
      Spacer(minLength: 0)
    }.appFont(.caption).padding(.horizontal, 12).padding(.top, 8)
  }

  private var selection: Binding<String> {
    Binding(get: {
      if let path = workspace.gitRepositoryRoot?.path { return path }
      if let path = workspace.selectedReviewRepository { return path }
      if let primary = workspace.reviewRepositories.first(where: { $0.isPrimary }) { return primary.id }
      return workspace.reviewRepositories.first?.id ?? ""
    }, set: { path in Task { await workspace.selectReviewRepository(path) } })
  }

  private func title(_ entry: GitReviewRepository) -> String {
    let sameNames = workspace.reviewRepositories.filter { $0.title == entry.title }.count > 1
    var label = sameNames ? entry.root.path : entry.title
    if entry.isPrimary { label += " · 主仓库" }
    if entry.readError != nil { label += " · 读取失败" }
    return label
  }
}
