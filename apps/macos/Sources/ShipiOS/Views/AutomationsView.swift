import SwiftUI

struct AutomationsView: View {
  enum Filter: String, CaseIterable, Identifiable {
    case all, active, paused
    var id: String { rawValue }
    var title: String {
      switch self { case .all: "全部"; case .active: "已启用"; case .paused: "已暂停" }
    }
  }

  @Bindable var store: WorkspaceStore
  @State private var filter = Filter.all
  @State private var query = ""
  @State private var editing: ShipAutomation?
  @State private var deleting: ShipAutomation?
  @State private var expandedHistories: Set<UUID> = []

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

  private func runs(for item: ShipAutomation) -> [AgentRun] {
    store.library.chatRuns.filter {
      $0.request["automation_id"].text == item.id.uuidString
    }.sorted { $0.createdAt > $1.createdAt }
  }

  private func projectLabel(for item: ShipAutomation) -> String {
    let paths = item.selectedProjects.filter { !$0.isEmpty }
    if paths.isEmpty { return "无项目" }
    if paths.count == 1 { return store.library.projectTitle(paths[0]) }
    return "\(paths.count) 个项目"
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
          item.environmentSelections = [:]
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
          if store.saveEditedAutomation(saved) { editing = nil }
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
          Text("\(item.unresolvedRunIDs.count) 次运行等待审查，打开结果并标记为已审查。")
            .appFont(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
      }.padding(14).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }.buttonStyle(.plain)
  }

  private func automationRow(_ item: ShipAutomation) -> some View {
    let history = runs(for: item)
    return VStack(alignment: .leading, spacing: 12) {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: item.enabled ? "clock.badge.checkmark" : "pause.circle")
        .font(.title2).frame(width: 32).foregroundStyle(item.enabled ? store.appearance.accentColor : .secondary)
      VStack(alignment: .leading, spacing: 7) {
        Text(item.name).appFont(.headline)
        Text(item.prompt).appFont(.caption).foregroundStyle(.secondary).lineLimit(2)
        HStack(spacing: 14) {
          Label(item.scheduleLabel, systemImage: "calendar")
          Label(projectLabel(for: item), systemImage: "folder")
          if item.enabled {
            Text("下次 \(item.nextRun.formatted(date: .abbreviated, time: .shortened))")
          } else { Text("已暂停") }
        }.appFont(.caption2).foregroundStyle(.tertiary)
        if !history.isEmpty {
          Button(expandedHistories.contains(item.id) ? "收起运行记录" : "运行记录（\(history.count)）") {
            if !expandedHistories.insert(item.id).inserted { expandedHistories.remove(item.id) }
          }.buttonStyle(.link).appFont(.caption)
        }
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
        if store.automationRunningIDs.contains(item.id), item.taskID != nil {
          Button("打开运行中的任务") { store.openAutomationCurrentTask(item.id) }
        }
        if let lastRunID = item.lastRunID {
          Button("打开上次结果") { store.openAutomationRun(lastRunID, automationID: item.id) }
        }
        Divider()
        Button("删除", role: .destructive) { deleting = item }
      } label: { Image(systemName: "ellipsis") }
        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("自动化菜单：\(item.name)")
    }
    if expandedHistories.contains(item.id) {
      ForEach(history) { run in
        Button { store.openAutomationRun(run.id, automationID: item.id) } label: {
          HStack {
            Text(run.date.formatted(date: .abbreviated, time: .shortened))
            Text(run.statusLabel).foregroundStyle(.secondary)
            if item.unresolvedRunIDs.contains(run.id) {
              Text("待审查").foregroundStyle(store.appearance.accentColor)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
          }.appFont(.caption)
        }.buttonStyle(.plain).padding(.leading, 46)
      }
    }
    }.padding(16).background(.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
  }
}

private struct AutomationEditorView: View {
  private static let defaultCustomRule = "RRULE:FREQ=MONTHLY;BYMONTHDAY=1;BYHOUR=9;BYMINUTE=0"
  @Bindable var store: WorkspaceStore
  @State var item: ShipAutomation
  @State private var modelCatalog = ModelCatalog()
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

  private var ruleText: Binding<String> {
    Binding(get: { item.customRule ?? "" }, set: { item.customRule = $0 })
  }

  private var ruleError: String? {
    guard item.cadence == .custom else { return nil }
    do {
      let rule = try AutomationRecurrenceRule.parse(item.customRule ?? "")
      guard rule.nextDate(after: .now, anchor: item.scheduleAnchor ?? .now,
        calendar: .current) != nil else {
        return "未来十年内找不到该 RRULE 的下次运行时间。"
      }
      return nil
    } catch { return error.localizedDescription }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(store.automationPreferences.items.contains(where: { $0.id == item.id }) ? "编辑自动化" : "新建自动化")
        .appFont(.title2, weight: .semibold)
      Form {
        TextField("名称", text: $item.name)
        VStack(alignment: .leading, spacing: 8) {
          Text("项目")
          Toggle("无项目", isOn: Binding(
            get: { item.selectedProjects == [""] },
            set: { item.setProject("", selected: $0) }))
            .toggleStyle(.checkbox)
          ForEach(store.library.orderedProjects, id: \.self) { path in
            Toggle(store.library.projectTitle(path), isOn: Binding(
              get: { item.selectedProjects.contains(path) },
              set: { item.setProject(path, selected: $0) }))
              .toggleStyle(.checkbox)
          }
        }
        Picker("运行位置", selection: Binding(
          get: { item.selectedExecution }, set: { item.execution = $0 })) {
          ForEach(NewTaskExecution.allCases) { Text($0.title).tag($0) }
        }
        if item.selectedExecution == .worktree {
          Text("Git 仓库根目录中的任务将在独立工作树运行；非 Git 项目仍在原目录运行。")
            .appFont(.caption).foregroundStyle(.secondary)
          ForEach(item.selectedProjects.filter { path in
            !path.isEmpty && FileManager.default.fileExists(
              atPath: URL(fileURLWithPath: path).appendingPathComponent(".git").path)
          }, id: \.self) { path in
            Picker("环境 · \(store.library.projectTitle(path))", selection: Binding(
              get: { item.environmentSelection(for: path) },
              set: { item.setEnvironment($0, for: path) })) {
              Text("项目默认").tag(AutomationEnvironmentChoice.projectDefault)
              Text("ShipiOS 本地配置").tag(WorktreeEnvironmentChoice.legacy)
              Text("无环境").tag(WorktreeEnvironmentChoice.none)
              ForEach(store.environmentCatalog[path]?.filter { $0.error == nil } ?? []) { entry in
                Text(entry.title).tag(entry.id)
              }
              let selected = item.environmentSelection(for: path)
              if selected != AutomationEnvironmentChoice.projectDefault,
                selected != WorktreeEnvironmentChoice.legacy,
                selected != WorktreeEnvironmentChoice.none,
                store.environmentCatalog[path]?.contains(where: { $0.id == selected && $0.error == nil }) != true {
                Text("所选环境已不可用").tag(selected)
              }
            }
          }
          if store.environmentCatalogLoading {
            ProgressView("正在读取项目环境…").controlSize(.small)
          }
          Button("刷新环境列表") { Task { await store.refreshEnvironmentCatalog() } }
            .buttonStyle(.link)
        }
        Picker("模型", selection: Binding(
          get: { item.modelID ?? "" },
          set: { item.modelID = $0.isEmpty ? nil : $0 })) {
          Text("沿用服务配置（\(store.modelConfiguration.model)）").tag("")
          ForEach(modelCatalog.choices(
            current: item.modelID ?? store.modelConfiguration.model, query: ""), id: \.self) { model in
            Text(modelCatalog.title(for: model)).tag(model)
          }
        }
        TextField("或输入模型 ID（留空沿用服务配置）", text: Binding(
          get: { item.modelID ?? "" },
          set: { item.modelID = $0.isEmpty ? nil : $0 }))
        Picker("推理强度", selection: Binding(
          get: { item.reasoning ?? "__follow_service__" },
          set: { item.reasoning = $0 == "__follow_service__" ? nil : $0 })) {
          Text("沿用服务配置").tag("__follow_service__")
          ForEach(modelCatalog.availableReasoning(
            for: item.modelID ?? store.modelConfiguration.model,
            advanced: store.library.enabledAdvancedReasoningEfforts), id: \.self) { effort in
            Text(AgentReasoningEfforts.titles[effort] ?? effort).tag(effort)
          }
          if let reasoning = item.reasoning,
            !modelCatalog.availableReasoning(for: item.modelID ?? store.modelConfiguration.model,
              advanced: store.library.enabledAdvancedReasoningEfforts).contains(reasoning) {
            Text(AgentReasoningEfforts.titles[reasoning] ?? reasoning).tag(reasoning)
          }
        }
        if let reasoning = item.reasoning,
          modelCatalog.isCurrentReasoningUnsupported(
            for: item.modelID ?? store.modelConfiguration.model, reasoning: reasoning) {
          Text("所选模型未声明支持此推理强度，请选择其他等级或服务默认。")
            .appFont(.caption).foregroundStyle(.orange)
        }
        Picker("频率", selection: $item.cadence) {
          ForEach(AutomationCadence.allCases) { Text($0.title).tag($0) }
        }
        .onChange(of: item.cadence) { _, cadence in
          if cadence == .custom && item.customRule == nil {
            item.customRule = Self.defaultCustomRule
          }
        }
        if item.cadence == .weekly {
          HStack {
            Text("星期")
            Spacer()
            ForEach(0..<7, id: \.self) { offset in
              let day = (Calendar.current.firstWeekday + offset - 1) % 7 + 1
              Button(Calendar.current.veryShortWeekdaySymbols[day - 1]) {
                item.setWeekday(day, selected: !item.selectedWeekdays.contains(day))
              }
              .buttonStyle(.bordered)
              .tint(item.selectedWeekdays.contains(day) ? store.appearance.accentColor : .gray)
              .accessibilityLabel(Calendar.current.weekdaySymbols[day - 1])
              .accessibilityAddTraits(item.selectedWeekdays.contains(day) ? .isSelected : [])
            }
          }
        }
        if item.cadence == .custom {
          TextField("RRULE", text: ruleText)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("自定义日程 RRULE")
          Text("支持小时、天、周、月频率与间隔，以及 BYDAY、BYMONTHDAY、BYHOUR、BYMINUTE 和 WKST。")
            .appFont(.caption).foregroundStyle(.secondary)
          if let ruleError {
            Text(ruleError).appFont(.caption).foregroundStyle(.red)
          } else {
            Text("下次运行：\(item.nextDate(after: .now).formatted(date: .abbreviated, time: .shortened))")
              .appFont(.caption).foregroundStyle(.secondary)
          }
        } else if item.cadence == .hourly {
          Picker("每小时的分钟", selection: $item.minute) {
            ForEach(0..<60, id: \.self) { minute in
              Text(String(format: "%02d", minute)).tag(minute)
            }
          }
        } else {
          DatePicker("时间", selection: time, displayedComponents: .hourAndMinute)
        }
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
          save(item)
        }.keyboardShortcut(.defaultAction)
          .disabled(item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || item.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (item.modelID?.contains(where: { $0.isWhitespace || $0.isNewline }) == true)
            || ruleError != nil)
      }
    }.padding(24).frame(width: 630, height: 680)
      .task { await modelCatalog.load(config: store.modelConfiguration) }
      .task { await store.refreshEnvironmentCatalog() }
  }
}
