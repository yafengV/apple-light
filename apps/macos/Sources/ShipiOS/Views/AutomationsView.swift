import SwiftUI

struct AutomationsView: View {
  enum Filter: String, CaseIterable, Identifiable {
    case all, active, paused
    var id: String { rawValue }
    var title: String {
      switch self { case .all: "全部"; case .active: "运行中"; case .paused: "已暂停" }
    }
  }

  @Bindable var store: WorkspaceStore
  @State private var filter = Filter.all
  @State private var query = ""
  @State private var editing: ShipAutomation?
  @State private var deleting: ShipAutomation?

  private var items: [ShipAutomation] {
    store.automationPreferences.items.filter { item in
      let stateMatches = filter == .all || (filter == .active) == item.enabled
      let textMatches = query.isEmpty || item.name.localizedCaseInsensitiveContains(query)
        || item.prompt.localizedCaseInsensitiveContains(query)
      return stateMatches && textMatches
    }
  }
  private var reviewItems: [ShipAutomation] {
    store.automationPreferences.items.filter(\.needsReview)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 12) {
        Text("自动化").appFont(.title2, weight: .semibold)
        Picker("筛选", selection: $filter) {
          ForEach(Filter.allCases) { Text($0.title).tag($0) }
        }.pickerStyle(.segmented).frame(width: 230)
        Spacer()
        Button("新建自动化") {
          var item = ShipAutomation()
          item.nextRun = item.nextDate(after: .now)
          editing = item
        }.disabled(!store.automationsLoaded)
        Button("返回任务") { store.returnToWorkspace() }.keyboardShortcut(.cancelAction)
      }
      TextField("搜索自动化", text: $query).textFieldStyle(.roundedBorder)
      if store.automationsLoading {
        ProgressView("正在读取自动化…").frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            if !reviewItems.isEmpty {
              Text("等待审查").appFont(.headline)
              ForEach(reviewItems) { item in reviewRow(item) }
            }
            HStack {
              Text("已安排").appFont(.headline)
              Spacer()
              Text("\(items.count) 项").appFont(.caption).foregroundStyle(.secondary)
            }
            if items.isEmpty {
              ContentUnavailableView(
                query.isEmpty ? "没有自动化" : "没有匹配的自动化",
                systemImage: "clock.arrow.circlepath",
                description: Text(query.isEmpty ? "创建一个自动执行的重复任务。" : "尝试其他搜索词。"))
                .frame(maxWidth: .infinity).padding(.top, 44)
            } else {
              ForEach(items) { item in automationRow(item) }
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      if let error = store.automationsError {
        HStack(alignment: .top) {
          Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
          Text(error).textSelection(.enabled)
          Spacer()
          Button("关闭") { store.automationsError = nil }
          Button("重新加载") { Task { await store.loadAutomations() } }
        }.padding(12).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
      }
    }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
      .sheet(item: $editing) { item in
        AutomationEditorView(store: store, item: item) { saved in
          if store.saveAutomation(saved) { editing = nil }
        }
      }
      .alert("删除自动化？", isPresented: Binding(
        get: { deleting != nil }, set: { if !$0 { deleting = nil } })
      ) {
        Button("取消", role: .cancel) { deleting = nil }
        Button("删除", role: .destructive) {
          if let deleting { store.deleteAutomation(deleting.id) }
          deleting = nil
        }
      } message: {
        Text("将删除日程“\(deleting?.name ?? "")”。已经生成的任务和结果会保留。")
      }
  }

  private func reviewRow(_ item: ShipAutomation) -> some View {
    Button { store.openAutomationResult(item.id) } label: {
      HStack(spacing: 12) {
        Image(systemName: "tray.full.fill").foregroundStyle(store.appearance.accentColor)
        VStack(alignment: .leading, spacing: 3) {
          Text(item.name).appFont(.headline)
          Text("最新运行已完成，打开结果并标记为已审查。")
            .appFont(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
      }.padding(14).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }.buttonStyle(.plain)
  }

  private func automationRow(_ item: ShipAutomation) -> some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: item.enabled ? "clock.badge.checkmark" : "pause.circle")
        .font(.title2).frame(width: 32).foregroundStyle(item.enabled ? store.appearance.accentColor : .secondary)
      VStack(alignment: .leading, spacing: 7) {
        Text(item.name).appFont(.headline)
        Text(item.prompt).appFont(.caption).foregroundStyle(.secondary).lineLimit(2)
        HStack(spacing: 14) {
          Label(item.scheduleLabel, systemImage: "calendar")
          Label(
            item.project.isEmpty ? "无项目" : store.library.projectTitle(item.project),
            systemImage: "folder")
          if item.enabled {
            Text("下次 \(item.nextRun.formatted(date: .abbreviated, time: .shortened))")
          } else { Text("已暂停") }
        }.appFont(.caption2).foregroundStyle(.tertiary)
      }.frame(maxWidth: .infinity, alignment: .leading)
      if store.automationRunningIDs.contains(item.id) {
        ProgressView().controlSize(.small).help("正在运行")
      } else {
        Button("运行") { Task { await store.runAutomation(item.id) } }
      }
      Toggle("启用", isOn: Binding(
        get: { item.enabled }, set: { store.setAutomationEnabled($0, id: item.id) }))
        .labelsHidden().help(item.enabled ? "暂停自动化" : "恢复自动化")
      Menu {
        Button("编辑…") { editing = item }
        if item.lastRunID != nil { Button("打开上次结果") { store.openAutomationResult(item.id) } }
        Divider()
        Button("删除", role: .destructive) { deleting = item }
      } label: { Image(systemName: "ellipsis") }
        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("自动化菜单：\(item.name)")
    }.padding(16).background(.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
  }
}

private struct AutomationEditorView: View {
  @Bindable var store: WorkspaceStore
  @State var item: ShipAutomation
  let save: (ShipAutomation) -> Void
  @Environment(\.dismiss) private var dismiss

  private var time: Binding<Date> {
    Binding {
      Calendar.current.date(from: DateComponents(hour: item.hour, minute: item.minute)) ?? .now
    } set: { value in
      let components = Calendar.current.dateComponents([.hour, .minute], from: value)
      item.hour = components.hour ?? 9
      item.minute = components.minute ?? 0
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(store.automationPreferences.items.contains(where: { $0.id == item.id }) ? "编辑自动化" : "新建自动化")
        .appFont(.title2, weight: .semibold)
      Form {
        TextField("名称", text: $item.name)
        Picker("项目", selection: $item.project) {
          Text("无项目").tag("")
          ForEach(store.library.orderedProjects, id: \.self) { path in
            Text(store.library.projectTitle(path)).tag(path)
          }
        }
        Picker("频率", selection: $item.cadence) {
          ForEach(AutomationCadence.allCases) { Text($0.title).tag($0) }
        }
        if item.cadence == .weekly {
          Picker("星期", selection: $item.weekday) {
            ForEach(Array(Calendar.current.weekdaySymbols.enumerated()), id: \.offset) { index, title in
              Text(title).tag(index + 1)
            }
          }
        }
        DatePicker("时间", selection: time, displayedComponents: .hourAndMinute)
        Toggle("启用", isOn: $item.enabled)
      }.formStyle(.grouped)
      VStack(alignment: .leading, spacing: 6) {
        Text("指令").appFont(.headline)
        TextEditor(text: $item.prompt).font(.body).frame(minHeight: 150)
          .padding(7).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
        Text("可在指令中使用已启用插件的 `@标识`。每次运行会创建或继续一个可审查的任务。")
          .appFont(.caption).foregroundStyle(.secondary)
      }
      HStack {
        Spacer()
        Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("保存") {
          item.nextRun = item.nextDate(after: .now)
          save(item)
        }.keyboardShortcut(.defaultAction)
          .disabled(item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || item.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }.padding(24).frame(width: 590, height: 600)
  }
}
