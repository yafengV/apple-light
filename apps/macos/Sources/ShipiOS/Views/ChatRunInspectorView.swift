import SwiftUI

/// The execution panel for model turns uses their actual run and tool records.
struct ChatRunInspectorView: View {
  @Bindable var store: WorkspaceStore
  let run: AgentRun
  @Binding var tab: String
  let close: () -> Void

  private var selectedTab: Binding<String> {
    Binding {
      ["overview", "tools", "output"].contains(tab) ? tab : "overview"
    } set: { tab = $0 }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("执行详情").appFont(.headline)
        Spacer()
        Button(action: close) {
          Image(systemName: "xmark")
        }.buttonStyle(.plain).help("关闭详情")
      }.padding(16)
      Picker("详情", selection: selectedTab) {
        Text("概览").tag("overview")
        Text("工具").tag("tools")
        Text("输出").tag("output")
      }.pickerStyle(.segmented).padding(.horizontal, 14).padding(.bottom, 14)
      Divider()
      HStack {
        StatusLabel(run: run)
        Spacer()
        Text(run.date, style: .time).foregroundStyle(.secondary)
      }.appFont(.caption).padding(14)
      switch selectedTab.wrappedValue {
      case "tools": tools
      case "output": output
      default: overview
      }
    }
  }

  private var overview: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        LabeledContent("模型", value: run.request["model"].text ?? "未知")
        LabeledContent("协议", value: run.request["api_protocol"].text == ModelAPIProtocol.codexResponses.rawValue
          ? "Codex Core · Responses" : "Chat Completions")
        LabeledContent("项目", value: run.project.isEmpty ? "无项目" : store.library.projectTitle(run.project))
        if let reasoning = run.request["reasoning_effort"].text, !reasoning.isEmpty {
          LabeledContent("推理强度", value: reasoning)
        }
        LabeledContent("开始", value: run.date.formatted(date: .abbreviated, time: .standard))
        if !run.isActive {
          LabeledContent("耗时", value: String(format: "%.1f 秒",
            max(0, (run.updatedAt - run.createdAt) / 1_000)))
        }
        if let usage = ModelTokenUsage(stored: run.result?["usage"] ?? .null) {
          Divider()
          LabeledContent("输入 token", value: usage.inputTokens.formatted())
          LabeledContent("输出 token", value: usage.outputTokens.formatted())
          LabeledContent("总 token", value: usage.totalTokens.formatted())
          if let cached = usage.cachedInputTokens {
            LabeledContent("缓存输入", value: cached.formatted())
          }
        }
        Divider()
        LabeledContent("工具调用", value: run.toolExecutions.count.formatted())
        if let message = run.result?["message"].text, !message.isEmpty {
          Text(message).foregroundStyle(.red).textSelection(.enabled)
        }
      }.appFont(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(16)
    }.frame(minHeight: 0, maxHeight: .infinity)
  }

  private var tools: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        if run.toolExecutions.isEmpty {
          ContentUnavailableView(
            run.isActive ? "等待工具调用" : "本轮没有工具调用",
            systemImage: "wrench.and.screwdriver")
            .frame(maxWidth: .infinity).padding(.top, 36)
        } else {
          ForEach(run.toolExecutions) { execution in
            MCPToolExecutionView(store: store, run: run, execution: execution)
              .environment(\.mcpApprovalSurfaceVisible, false)
          }
        }
      }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
    }.frame(minHeight: 0, maxHeight: .infinity)
  }

  private var output: some View {
    ScrollView([.horizontal, .vertical]) {
      Text(run.result?["response"].text.flatMap { $0.isEmpty ? nil : $0 }
        ?? (run.isActive ? "正在生成回复…" : "本轮没有文字输出。"))
        .appFont(.callout).textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
    }.defaultScrollAnchor(.topLeading).frame(minHeight: 0, maxHeight: .infinity)
  }
}
