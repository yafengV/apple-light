import SwiftUI

struct ComposerModelPicker: View {
  @Bindable var store: WorkspaceStore
  var taskID: String? = nil
  var onClose: (() -> Void)? = nil
  var onSettings: (() -> Void)? = nil
  private var configuration: ModelConfiguration { store.modelConfiguration(for: taskID) }
  @State private var catalog = ModelCatalog()
  @State private var query = ""
  @State private var highlighted: String?
  @State private var refresh = UUID()
  @State private var saveError: String?
  @State private var showingModels = false
  @FocusState private var searching: Bool

  private var choices: [String] {
    catalog.choices(current: configuration.model, query: query)
  }
  private var efforts: [String] {
    catalog.availableReasoning(for: configuration.model,
      advanced: store.library.enabledAdvancedReasoningEfforts)
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
          Button { showingModels = false; searching = false } label: {
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
            searching = true
          } label: {
            HStack(spacing: 5) {
              Text(catalog.title(for: configuration.model)).lineLimit(1)
              Image(systemName: "chevron.right").font(.caption)
            }
          }.buttonStyle(.plain).accessibilityLabel("更换模型：\(configuration.model)")
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
        if defaultPower != nil {
          Button("使用默认档位", action: resetToDefaultPower)
            .accessibilityLabel("使用默认模型与推理档位")
        }
        TextField("搜索或输入模型 ID", text: $query)
          .textFieldStyle(.roundedBorder).focused($searching)
          .accessibilityLabel("搜索模型")
          .task {
            searching = false
            await Task.yield()
            guard !Task.isCancelled else { return }
            searching = true
          }
          .onKeyPress(.downArrow) { move(1); return .handled }
          .onKeyPress(.upArrow) { move(-1); return .handled }
          .onSubmit {
            if let model = highlighted ?? choices.first { choose(model) }
            else if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { choose(query) }
          }
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(spacing: 2) {
              ForEach(choices, id: \.self) { model in
                Button { choose(model) } label: {
                  HStack {
                    VStack(alignment: .leading, spacing: 2) {
                      Text(catalog.title(for: model)).lineLimit(1)
                      if let subtitle = catalog.subtitle(for: model) {
                        Text(subtitle).appFont(.caption).foregroundStyle(.secondary).lineLimit(2)
                      }
                    }.multilineTextAlignment(.leading)
                    Spacer()
                    if configuration.model == model {
                      Image(systemName: "checkmark").accessibilityLabel("当前模型")
                    }
                  }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .background(
                      highlighted == model ? Color.primary.opacity(0.08) : .clear,
                      in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain).id(model).accessibilityLabel("选择模型：\(model)")
              }
              if choices.isEmpty {
                Text(catalog.loading ? "正在获取模型…" : "没有匹配的模型")
                  .foregroundStyle(.secondary).padding(8)
              }
            }
          }.frame(height: min(230, max(44, CGFloat(choices.count) * 56)))
            .onChange(of: highlighted) { _, model in
              if let model { proxy.scrollTo(model) }
            }
        }
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !choices.contains(query.trimmingCharacters(in: .whitespacesAndNewlines))
        {
          Button("使用模型 ID：\(query)") { choose(query) }
            .lineLimit(2).help("使用服务商提供的模型 ID")
        }
        if catalog.loading {
          ProgressView("正在获取模型列表…").controlSize(.small)
        } else if let error = catalog.error {
          Text(error).appFont(.caption).foregroundStyle(.secondary)
        }
        Divider()
        Picker(
          "推理强度",
          selection: Binding(
            get: { configuration.reasoning },
            set: { selectReasoning($0) })
        ) {
          ForEach(efforts, id: \.self) { effort in
            Text(AgentReasoningEfforts.titles[effort] ?? effort).tag(effort)
          }
          if !efforts.contains(configuration.reasoning) {
            Text(configuration.reasoning).tag(configuration.reasoning)
          }
        }.disabled(configuration.model.isEmpty)
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
    .task {
      highlighted = choices.first
      await Task.yield()
      guard !Task.isCancelled else { return }
      searching = !showingPower
    }
    .onChange(of: choices) { _, choices in
      if !choices.contains(highlighted ?? "") { highlighted = choices.first }
    }
    .onChange(of: showingPower) { _, value in
      searching = !value
    }
    .onExitCommand(perform: close)
  }

  private func close() {
    if let onClose { onClose() }
    else { store.showingModelPicker = false; store.focusComposer = UUID() }
  }

  private func move(_ offset: Int) {
    guard !choices.isEmpty else { return }
    let index = highlighted.flatMap { choices.firstIndex(of: $0) } ?? (offset > 0 ? -1 : 0)
    highlighted = choices[(index + offset + choices.count) % choices.count]
  }

  private func choose(_ model: String) {
    do {
      try store.setModelPickerSelectionMode(.model)
      try store.selectModel(model,
        reasoning: catalog.reasoningWhenSelecting(model, current: configuration.reasoning), taskID: taskID)
      close()
    } catch { saveError = error.localizedDescription }
  }

  private func selectReasoning(_ reasoning: String) {
    do {
      try store.selectModel(configuration.model, reasoning: reasoning, taskID: taskID)
      saveError = nil
    } catch { saveError = error.localizedDescription }
  }

  private func selectPower(_ selection: ModelPowerSelection) {
    do {
      try store.selectModel(selection.model, reasoning: selection.reasoningEffort, taskID: taskID)
      saveError = nil
    } catch { saveError = error.localizedDescription }
  }

  private func resetToDefaultPower() {
    guard let defaultPower else { return }
    do {
      try store.setModelPickerSelectionMode(.default)
      try store.selectModel(defaultPower.model, reasoning: defaultPower.reasoningEffort, taskID: taskID)
      saveError = nil; showingModels = false; searching = false
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
