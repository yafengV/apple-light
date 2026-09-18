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
  @FocusState private var searching: Bool

  private var choices: [String] {
    catalog.choices(current: configuration.model, query: query)
  }
  private let efforts = ["", "low", "medium", "high"]
  private let effortNames = ["": "服务默认", "low": "低", "medium": "中", "high": "高"]

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("选择模型").appFont(.headline)
        Spacer()
        Button {
          refresh = UUID()
        } label: {
          Image(systemName: "arrow.clockwise")
        }.buttonStyle(.plain).help("刷新服务的模型列表")
          .accessibilityLabel("刷新模型列表").disabled(catalog.loading)
      }
      TextField("搜索或输入模型 ID", text: $query)
        .textFieldStyle(.roundedBorder).focused($searching)
        .accessibilityLabel("搜索模型")
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
                  Text(model).lineLimit(2).multilineTextAlignment(.leading)
                  Spacer()
                  if configuration.model == model {
                    Image(systemName: "checkmark").accessibilityLabel("当前模型")
                  }
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                  .contentShape(Rectangle())
                  .background(
                    highlighted == model ? Color.primary.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
              }.buttonStyle(.plain).id(model)
            }
            if choices.isEmpty {
              Text(catalog.loading ? "正在获取模型…" : "没有匹配的模型")
                .foregroundStyle(.secondary).padding(8)
            }
          }
        }.frame(maxHeight: 230)
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
        ForEach(efforts, id: \.self) { effort in Text(effortNames[effort]!).tag(effort) }
        if !efforts.contains(configuration.reasoning) {
          Text(configuration.reasoning).tag(configuration.reasoning)
        }
      }.disabled(configuration.model.isEmpty)
      Text("模型列表由当前服务提供；推理强度是否可用取决于所选模型。更改用于下一次请求。")
        .appFont(.caption).foregroundStyle(.secondary)
      if let saveError { Text(saveError).appFont(.caption).foregroundStyle(.red) }
      HStack {
        Button("模型与 API 设置…") { if let onSettings { onSettings() } else { store.openSettings(.model) } }.buttonStyle(.plain)
        Spacer()
        Button("完成", action: close)
      }
    }
    .padding(16).frame(width: 340).appFont(.callout)
    .task(id: "\(store.modelConfiguration.credentialAccount)|\(refresh)") {
      await catalog.load(config: store.modelConfiguration)
    }
    .task {
      highlighted = choices.first
      await Task.yield()
      guard !Task.isCancelled else { return }
      searching = true
    }
    .onChange(of: choices) { _, choices in
      if !choices.contains(highlighted ?? "") { highlighted = choices.first }
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
      try store.selectModel(model, reasoning: configuration.reasoning, taskID: taskID)
      close()
    } catch { saveError = error.localizedDescription }
  }

  private func selectReasoning(_ reasoning: String) {
    do {
      try store.selectModel(configuration.model, reasoning: reasoning, taskID: taskID)
      saveError = nil
    } catch { saveError = error.localizedDescription }
  }
}
