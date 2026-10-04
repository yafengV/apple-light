import AppKit
import SwiftUI

private struct HookReviewSizeKey: PreferenceKey {
  static var defaultValue: [String: CGFloat] = [:]
  static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
    value.merge(nextValue(), uniquingKeysWith: { _, new in new })
  }
}

struct HookReviewDialog: View {
  @Bindable var store: WorkspaceStore
  let sourceID: String
  @Environment(\.appAppearance) private var appearance
  @State private var events: Set<String> = []
  @State private var expandedHandlers: [String: String] = [:]
  @State private var issuesExpanded = false
  @State private var headerHeight: CGFloat = 100
  @State private var contentHeight: CGFloat = 200
  @FocusState private var focused: Action?

  enum Action: Hashable {
    case close, trustAll, issues, event(String), handler(String), trust(String), toggle(String), open(String)
  }
  private var source: HookSettingsGroup? { store.hookSettings.groups.first { $0.id == sourceID } }
  private var busy: Bool { store.hookSettings.busy || store.hookSettings.loading }
  private var actions: [Action] {
    guard let source else { return [.close] }
    var result: [Action] = [.close]
    if source.reviewCount > 0 { result.append(.trustAll) }
    if !source.warnings.isEmpty { result.append(.issues) }
    for event in source.eventNames {
      result.append(.event(event))
      if events.contains(event) {
        for hook in source.hooks where hook.eventName == event {
          result.append(.handler(hook.id)); result.append(.open(hook.id))
          if hook.needsReview { result.append(.trust(hook.id)) }
          else if !hook.managed { result.append(.toggle(hook.id)) }
        }
      }
    }
    return result
  }
  static func next(_ current: Action?, actions: [Action], backwards: Bool) -> Action? {
    guard !actions.isEmpty else { return nil }
    guard let current, let index = actions.firstIndex(of: current) else {
      return backwards ? actions.last : actions.first
    }
    return actions[(index + (backwards ? -1 : 1) + actions.count) % actions.count]
  }

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        Color.black.opacity(0.3).contentShape(Rectangle())
          .onTapGesture { store.hookSettings.close() }.accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 0) {
          HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
              Text(source?.name ?? "Hooks").appFont(size: 20, weight: .semibold).accessibilityAddTraits(.isHeader)
              Text(source?.label ?? "").foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            Button { activate(.close) } label: { Image(systemName: "xmark") }
              .buttonStyle(.plain).accessibilityLabel("关闭 Hook 来源")
              .settingsActionFocus($focused, equals: .close, activate: { activate(.close) })
          }.padding(24).background(GeometryReader { proxy in
            Color.clear.preference(key: HookReviewSizeKey.self, value: ["header": proxy.size.height])
          })
          Divider()
          ScrollViewReader { proxy in
            ScrollView {
              VStack(alignment: .leading, spacing: 16) {
                if let source {
                  if !source.pluginEnabled { Text("此插件已停用，Hooks 不会运行。关闭此页面后可在插件设置中启用。").foregroundStyle(.secondary) }
                  if source.reviewCount > 0 {
                    HStack(alignment: .top, spacing: 12) {
                      Label("Hooks 在沙箱之外运行，可能执行不安全的操作。信任前请检查完整定义。", systemImage: "exclamationmark.triangle")
                        .fixedSize(horizontal: false, vertical: true)
                      Spacer(minLength: 0)
                      Button("全部信任") { activate(.trustAll) }
                        .settingsActionFocus($focused, equals: .trustAll, activate: { activate(.trustAll) }).id(Action.trustAll)
                    }.padding(12).background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                  }
                  if let error = store.hookSettings.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                  if !source.warnings.isEmpty { issues(source) }
                  if source.hooks.isEmpty, source.warnings.isEmpty { Text("未找到可用 Hooks").foregroundStyle(.secondary) }
                  ForEach(source.eventNames, id: \.self) { event in eventGroup(event, source: source) }
                }
              }.padding(24).background(GeometryReader { proxy in
                Color.clear.preference(key: HookReviewSizeKey.self, value: ["content": proxy.size.height])
              })
            }.onChange(of: focused) { _, action in
              if let action { withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(action, anchor: .center) } }
            }
          }
          if busy { ProgressView("正在更新 Hooks…").controlSize(.small).padding(12) }
        }
        .frame(width: min(768, max(0, geometry.size.width - 64)),
          height: min(680, max(0, geometry.size.height - 64), headerHeight + contentHeight + (busy ? 44 : 0) + 1))
        .onPreferenceChange(HookReviewSizeKey.self) { sizes in
          if let height = sizes["header"], height.isFinite { headerHeight = height }
          if let height = sizes["content"], height.isFinite { contentHeight = height }
        }
        .background(appearance.resolvedColors["surface"].color, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(appearance.resolvedColors["border"].color, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
        .disabled(busy)
        .accessibilityElement(children: .contain).accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("hook-source-review-dialog")
        .background(HookReviewKeyboardBridge(ready: { focused = .close }) { key in
          switch key {
          case .cancel: activate(.close)
          case .activate: if let focused { activate(focused) }
          case .next, .previous:
            focused = Self.next(focused, actions: busy ? [] : actions, backwards: key == .previous)
          }
        }.frame(width: 0, height: 0))
      }
    }
    .onChange(of: actions) { _, current in if let focused, !current.contains(focused) { self.focused = .close } }
    .onChange(of: busy) { _, value in if !value, focused == nil { focused = .close } }
  }

  private func issues(_ source: HookSettingsGroup) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Button { activate(.issues) } label: {
        Label("配置问题", systemImage: issuesExpanded ? "chevron.down" : "chevron.right")
      }.buttonStyle(.plain).settingsActionFocus($focused, equals: .issues, activate: { activate(.issues) }).id(Action.issues)
      if issuesExpanded {
        ForEach(Array(source.warnings.enumerated()), id: \.offset) { _, warning in
          Text(warning).appFont(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
      }
    }
  }
  private func eventGroup(_ event: String, source: HookSettingsGroup) -> some View {
    let hooks = source.hooks.filter { $0.eventName == event }
    return VStack(alignment: .leading, spacing: 0) {
      Button { activate(.event(event)) } label: {
        HStack {
          Image(systemName: events.contains(event) ? "chevron.down" : "chevron.right")
          VStack(alignment: .leading, spacing: 3) {
            Text(hooks.first?.eventTitle ?? event).appFont(.subheadline)
            Text(hooks.first?.eventDescription ?? "").appFont(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Text("\(source.pluginEnabled ? hooks.filter(\.active).count : 0)/\(hooks.count) 已启用")
            .appFont(.caption).foregroundStyle(.secondary)
        }.padding(12)
      }.buttonStyle(.plain).settingsActionFocus($focused, equals: .event(event), activate: { activate(.event(event)) })
        .accessibilityValue(events.contains(event) ? "已展开" : "已折叠").id(Action.event(event))
      if events.contains(event) {
        ForEach(Array(hooks.enumerated()), id: \.element.id) { index, hook in
          Divider(); handler(hook, index: index)
        }
      }
    }.background(appearance.resolvedColors["panelBackground"].color, in: RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(appearance.resolvedColors["border"].color, lineWidth: 0.5))
  }
  private func handler(_ hook: HookMetadata, index: Int) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 12) {
        Button { activate(.handler(hook.id)) } label: {
          HStack(spacing: 8) {
            Image(systemName: expandedHandlers[hook.eventName] == hook.id ? "chevron.down" : "chevron.right")
            Text(hook.title(index: index)).frame(maxWidth: .infinity, alignment: .leading)
          }
        }.buttonStyle(.plain).settingsActionFocus($focused, equals: .handler(hook.id), activate: { activate(.handler(hook.id)) })
          .accessibilityValue(expandedHandlers[hook.eventName] == hook.id ? "已展开" : "已折叠").id(Action.handler(hook.id))
        Button { activate(.open(hook.id)) } label: { Image(systemName: "arrow.up.right.square") }
          .buttonStyle(.plain).accessibilityLabel("打开 Hook 配置文件")
          .settingsActionFocus($focused, equals: .open(hook.id), activate: { activate(.open(hook.id)) }).id(Action.open(hook.id))
        if hook.needsReview {
          Button("信任") { activate(.trust(hook.id)) }
            .help(hook.trustStatus == "modified" ? "Hook 自上次信任后发生变化" : "新 Hook")
            .settingsActionFocus($focused, equals: .trust(hook.id), activate: { activate(.trust(hook.id)) }).id(Action.trust(hook.id))
        }
        Toggle(hook.title(index: index), isOn: Binding(get: { hook.active }, set: { _ in activate(.toggle(hook.id)) }))
          .labelsHidden().toggleStyle(SettingsSwitchStyle()).disabled(hook.needsReview || hook.managed || busy)
          .settingsActionFocus($focused, equals: .toggle(hook.id), activate: { activate(.toggle(hook.id)) }).id(Action.toggle(hook.id))
      }
      if expandedHandlers[hook.eventName] == hook.id {
        VStack(alignment: .leading, spacing: 8) {
          LabeledContent("来源", value: source?.sources.first(where: { $0.id == hook.sourceId })?.label ?? "")
          LabeledContent("类型", value: hook.handler["type"].text ?? "")
          if let matcher = hook.matcher { LabeledContent("匹配", value: matcher) }
          LabeledContent("超时", value: "\(hook.timeoutSec) 秒")
          if let limit = hook.additionalContextLimit { LabeledContent("附加上下文上限", value: String(limit)) }
          Text(hook.definition.pretty).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }.appFont(.caption).padding(.leading, 22)
      }
    }.padding(12).disabled(busy)
  }
  private func activate(_ action: Action) {
    guard store.hookSettings.selectedSourceID == sourceID, !busy else { return }
    switch action {
    case .close: store.hookSettings.close()
    case .issues: issuesExpanded.toggle()
    case .event(let event): if events.contains(event) { events.remove(event) } else { events.insert(event) }
    case .handler(let key):
      if let hook = source?.hooks.first(where: { $0.id == key }) {
        expandedHandlers[hook.eventName] = expandedHandlers[hook.eventName] == key ? nil : key
      }
    case .open:
      if case .open(let key) = action, let hook = source?.hooks.first(where: { $0.id == key }),
        let file = source?.sources.first(where: { $0.id == hook.sourceId })?.fileURL,
        FileManager.default.fileExists(atPath: file.path) { NSWorkspace.shared.open(file) }
    case .trustAll:
      if let hooks = source?.hooks.filter(\.needsReview) { change(hooks, trust: true) }
    case .trust(let key):
      if let hook = source?.hooks.first(where: { $0.id == key && $0.needsReview }) { change([hook], trust: true) }
    case .toggle(let key):
      if let hook = source?.hooks.first(where: { $0.id == key && !$0.needsReview && !$0.managed }) {
        change([hook], enabled: !hook.enabled)
      }
    }
  }
  private func change(_ hooks: [HookMetadata], enabled: Bool? = nil, trust: Bool = false) {
    Task { await store.hookSettings.change(sourceID: sourceID, expected: hooks,
      enabled: enabled, trust: trust, executable: store.executable) }
  }
}
