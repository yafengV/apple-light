import SwiftUI

struct ComposerModelPicker: View {
  @Bindable var store: WorkspaceStore
  var taskID: String? = nil
  var onClose: (() -> Void)? = nil
  var onSettings: (() -> Void)? = nil
  private var configuration: ModelConfiguration { store.modelConfiguration(for: taskID) }
  @State private var catalog = ModelCatalog()
  @State private var refresh = UUID()
  @State private var saveError: String?
  @State private var showingModels = false
  @State private var menuFocus = ModelPickerMenuFocus()

  private var choices: [String] {
    catalog.models
  }
  private var powerSelections: [ModelPowerSelection] {
    catalog.powerSelections(for: configuration.model, current: configuration.reasoning,
      mode: store.library.modelPickerSelectionMode,
      advanced: store.library.enabledAdvancedReasoningEfforts)
  }
  private var selectedPower: ModelPowerSelection? {
    catalog.selectedPower(in: powerSelections, model: configuration.model, reasoning: configuration.reasoning)
  }
  private var showingPower: Bool { !showingModels && selectedPower != nil }
  private var defaultPower: ModelPowerSelection? {
    catalog.fallbackPowerSelection(advanced: store.library.enabledAdvancedReasoningEfforts)
  }
  private var usingDefaultPower: Bool {
    store.library.modelPickerSelectionMode != .model && selectedPower.map {
      catalog.defaultPowerSelections(advanced: store.library.enabledAdvancedReasoningEfforts).contains($0)
    } == true
  }
  private struct MenuConfiguration: Equatable {
    let ids: [String]
    let preferredID: String?
    let active: Bool
  }
  private var defaultSelected: Bool {
    store.library.modelPickerSelectionMode == .default ||
      (store.library.modelPickerSelectionMode == nil && usingDefaultPower)
  }
  private var menuConfiguration: MenuConfiguration {
    let ids = (defaultPower == nil ? [] : ["default"]) + choices.map { "model:\($0)" }
    return .init(ids: ids, preferredID: defaultSelected && defaultPower != nil
      ? "default" : "model:\(configuration.model)", active: !showingPower && !catalog.loading && canInteract)
  }
  private var canInteract: Bool {
    store.libraryLoaded && !store.libraryRecoveryBlocksInteraction && !store.shuttingDown
  }
  private func powerTitle(_ selection: ModelPowerSelection?) -> String {
    guard let selection else { return currentReasoningTitle }
    let effort = AgentReasoningEfforts.titles[selection.reasoningEffort] ?? selection.reasoningEffort
    return usingDefaultPower ? "\(catalog.title(for: selection.model)) · \(effort)" : effort
  }
  private var defaultReasoningTitle: String {
    guard let effort = catalog.defaultReasoningEffort(for: configuration.model) else {
      return "服务默认"
    }
    return "服务默认（\(AgentReasoningEfforts.titles[effort] ?? effort)）"
  }
  private var currentReasoningTitle: String {
    configuration.reasoning.isEmpty ? defaultReasoningTitle
      : (AgentReasoningEfforts.titles[configuration.reasoning] ?? configuration.reasoning)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        if showingModels && selectedPower != nil {
          Button { showingModels = false } label: {
            Image(systemName: "chevron.left")
          }.buttonStyle(.plain).accessibilityLabel("返回推理档位")
        }
        Text(showingPower ? "模型与推理" : "选择模型").appFont(.headline)
        Spacer()
        Button {
          refresh = UUID()
        } label: {
          Image(systemName: "arrow.clockwise")
        }.buttonStyle(.plain).help("刷新服务的模型列表")
          .accessibilityLabel("刷新模型列表").disabled(catalog.loading)
      }
      if showingPower {
        HStack {
          Text("模型").foregroundStyle(.secondary)
          Spacer()
          Button {
            showingModels = true
          } label: {
            HStack(spacing: 5) {
              Text(catalog.title(for: configuration.model)).lineLimit(1)
              Image(systemName: "chevron.right").font(.caption)
            }
          }.buttonStyle(.plain).accessibilityLabel("更换模型：\(configuration.model)")
          if !usingDefaultPower, defaultPower != nil {
            Button(action: resetToDefaultPower) {
              Image(systemName: "arrow.uturn.backward")
            }.buttonStyle(.plain).help("恢复默认模型与推理档位")
              .accessibilityLabel("使用默认模型与推理档位")
          }
        }
        Text(powerTitle(selectedPower))
          .appFont(.caption).foregroundStyle(.secondary)
        HStack {
          Text("推理强度")
          ModelPowerSlider(value: Binding(
          get: { Double(powerSelections.firstIndex(where: { $0.id == selectedPower?.id }) ?? 0) },
          set: { value in
            guard showingPower, value.isFinite, !powerSelections.isEmpty else { return }
            let index = Int(min(max(value.rounded(), 0), Double(powerSelections.count - 1)))
            guard powerSelections[index].id != selectedPower?.id else { return }
            selectPower(powerSelections[index])
          }), count: powerSelections.count,
            valueDescription: powerTitle(selectedPower),
            available: { showingPower && store.libraryLoaded && !store.libraryRecoveryBlocksInteraction && !store.shuttingDown },
            onStep: { _ = stepPower(increasing: $0) }, onComplete: close)
            .frame(height: 28)
        }
        HStack {
          Text(powerTitle(powerSelections.first))
          Spacer()
          Text(powerTitle(powerSelections.last))
        }.appFont(.caption).foregroundStyle(.secondary)
      } else {
        ScrollView {
          VStack(spacing: 2) {
            if defaultPower != nil {
              ModelPickerMenuItem(id: "default", title: "默认", subtitle: "推荐模型组合",
                label: "默认：推荐模型组合", selected: defaultSelected, navigation: menuFocus,
                available: { canInteract }) {
                  if defaultSelected { showingModels = false }
                  else { resetToDefaultPower() }
                }.frame(height: 52)
            }
            ForEach(choices, id: \.self) { model in
              ModelPickerMenuItem(id: "model:\(model)", title: catalog.title(for: model),
                subtitle: catalog.subtitle(for: model), label: "选择模型：\(model)",
                selected: !defaultSelected && configuration.model == model,
                navigation: menuFocus, available: { canInteract }) { choose(model) }
                .frame(height: catalog.subtitle(for: model) == nil ? 34 : 52)
            }
            if choices.isEmpty {
              Text(catalog.loading ? "正在获取模型…" : "没有可用的模型")
                .foregroundStyle(.secondary).padding(8)
            }
          }
        }.frame(height: min(230, max(44, CGFloat(choices.count) * 42 + (defaultPower == nil ? 0 : 54))))
        if catalog.loading {
          ProgressView("正在获取模型列表…").controlSize(.small)
        } else if let error = catalog.error {
          Text(error).appFont(.caption).foregroundStyle(.secondary)
        }
      }
      Text("模型列表由当前服务提供；推理强度是否可用取决于所选模型。更改用于下一次请求。")
        .appFont(.caption).foregroundStyle(.secondary)
      if catalog.isCurrentReasoningUnsupported(for: configuration.model, reasoning: configuration.reasoning) {
        Text("当前推理强度不在此模型声明的支持列表中；请选择其他等级或服务默认值。")
          .appFont(.caption).foregroundStyle(.orange)
      }
      if let saveError { Text(saveError).appFont(.caption).foregroundStyle(.red) }
      HStack {
        Button("模型与 API 设置…") { if let onSettings { onSettings() } else { store.openSettings(.model) } }.buttonStyle(.plain)
        Spacer()
        Button("完成", action: close)
      }
    }
    .padding(16).frame(width: 340).appFont(.callout)
    .task(id: "\(configuration.credentialAccount)|\(configuration.apiProtocol.rawValue)|\(refresh)") {
      let config = configuration
      await catalog.load(config: config)
      store.captureSkillModelMetadata(catalog, config: config)
    }
    .onChange(of: menuConfiguration, initial: true) { _, configuration in
      menuFocus.configure(ids: configuration.ids, preferredID: configuration.preferredID,
        active: configuration.active)
    }
    .onDisappear { menuFocus.deactivate() }
    .onExitCommand(perform: close)
  }

  private func close() {
    if let onClose { onClose() }
    else { store.showingModelPicker = false; store.focusComposer = UUID() }
  }

  private func choose(_ model: String) {
    do {
      if store.library.modelPickerSelectionMode != .model || configuration.model != model {
        try store.setModelPickerSelectionMode(.model)
        try store.selectModel(model,
          reasoning: catalog.reasoningWhenSelecting(model, current: configuration.reasoning), taskID: taskID)
      }
      saveError = nil; showingModels = false
    } catch { saveError = error.localizedDescription }
  }

  private func selectPower(_ selection: ModelPowerSelection) {
    do {
      try store.selectModel(selection.model, reasoning: selection.reasoningEffort, taskID: taskID)
      saveError = nil
    } catch { saveError = error.localizedDescription }
  }

  private func resetToDefaultPower() {
    do {
      try store.selectDefaultPower(from: catalog, taskID: taskID)
      saveError = nil; showingModels = false
    } catch { saveError = error.localizedDescription }
  }

  private func stepPower(increasing: Bool) -> KeyPress.Result {
    guard showingPower, let selectedPower,
      let index = powerSelections.firstIndex(of: selectedPower) else { return .ignored }
    let target = powerSelections[min(max(index + (increasing ? 1 : -1), 0), powerSelections.count - 1)]
    if target != selectedPower { selectPower(target) }
    return .handled
  }
}
