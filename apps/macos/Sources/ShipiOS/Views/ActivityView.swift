import SwiftUI

struct ActivityView: View {
  @Bindable var store: WorkspaceStore
  @State private var filter = ActivityFilter.all
  @State private var opening: String?

  private var items: [ActivityTaskEntry] { store.activityEntries.filter(filter.includes) }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 12) {
        Text("活动").appFont(.title2, weight: .semibold)
        Spacer()
        Picker("筛选活动", selection: $filter) {
          ForEach(ActivityFilter.allCases) { Text($0.title).tag($0) }
        }.pickerStyle(.menu).frame(width: 150)
        Button("全部标为已读") { store.clearUnreadTasks() }
          .disabled(store.library.unreadTasks.isEmpty)
        Button("返回任务") { store.returnToWorkspace() }.keyboardShortcut(.cancelAction)
      }
      Text("查看未读、运行中和等待你处理的任务。")
        .appFont(.callout).foregroundStyle(.secondary)
      if let error = store.activityError {
        HStack {
          Text(error).foregroundStyle(.orange).textSelection(.enabled)
          Spacer()
          Button("关闭") { store.activityError = nil }
        }.appFont(.caption)
      }
      if items.isEmpty {
        ContentUnavailableView(filter == .all ? "暂无活动" : "没有匹配的任务",
          systemImage: "bell", description: Text("有新进展或需要处理的请求时，会显示在这里。"))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(spacing: 8) {
            ForEach(items) { item in row(item) }
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func row(_ item: ActivityTaskEntry) -> some View {
    Button {
      guard opening == nil else { return }
      opening = item.id
      Task {
        _ = await store.openActivityTask(item.id)
        opening = nil
      }
    } label: {
      HStack(spacing: 14) {
        Image(systemName: item.statusIcon)
          .foregroundStyle(item.attention != nil ? .orange : store.appearance.accentColor)
          .frame(width: 22)
        VStack(alignment: .leading, spacing: 5) {
          Text(item.task.title.isEmpty ? "未命名任务" : item.task.title)
            .appFont(.body, weight: .medium).lineLimit(1)
          HStack(spacing: 7) {
            Text(item.statusTitle)
            if !item.task.project.isEmpty {
              Text("·")
              Text(store.library.projectTitle(item.task.project))
            }
          }.appFont(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer(minLength: 10)
        if opening == item.id { ProgressView().controlSize(.small) }
        else { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
      }
      .padding(14).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
      .contentShape(Rectangle())
    }.buttonStyle(.plain).disabled(opening != nil || !store.canSelectTask(item.task))
      .accessibilityLabel("\(item.task.title)，\(item.statusTitle)")
  }
}
