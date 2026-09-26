import SwiftUI

struct ConversationView: View {
  @Bindable var store: WorkspaceStore
  var body: some View {
    if let task = store.selectedTask {
      ConversationTimelineView(store: store).id(task.id)
    } else {
      VStack(spacing: 24) {
        Spacer()
        Image(systemName: "sparkle").appFont(size: 34, weight: .light).foregroundStyle(
          .secondary)
        VStack(spacing: 10) {
          Text("准备好开始了吗？").appFont(size: 29, weight: .medium)
          Text(store.project.map { store.library.projectTitle($0.path) } ?? "直接开始对话，或选择一个项目。")
            .appFont(.title3).foregroundStyle(.secondary)
        }
        if store.personalization.showSuggestedPrompts {
          HStack(spacing: 10) {
            if store.project == nil {
              suggestion("讨论想法", "lightbulb", "把想法整理为可执行的计划") {
                store.action = .chat
                store.draft = "帮我将以下想法整理成计划："
                store.focusComposer = UUID()
              }
              suggestion("梳理问题", "text.bubble", "一起分析和解决问题") {
                store.action = .chat
                store.draft = "帮我分析这个问题："
                store.focusComposer = UUID()
              }
            } else {
              suggestion("检查开发环境", "stethoscope", "查看 Xcode 与项目状态") {
                store.action = .doctor
                store.draft = "检查当前项目的开发环境"
                store.focusComposer = UUID()
              }
              suggestion("构建项目", "hammer", "编译并收集诊断结果") {
                store.action = .build
                store.draft = "构建项目，检查编译结果"
                store.focusComposer = UUID()
              }
            }
          }.frame(maxWidth: 570)
        }
        if store.project == nil {
          HStack {
            Button("打开项目…") { store.chooseProject() }
            Button("试用示例项目") { Task { await store.openDemo() } }
          }.buttonStyle(.borderless).disabled(store.busy)
        }
        Spacer()
        Spacer().frame(height: 20)
      }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
  private func suggestion(
    _ title: String, _ icon: String, _ subtitle: String, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 9) {
        Label(title, systemImage: icon).appFont(size: 12, weight: .medium)
        Text(subtitle).appFont(.caption).foregroundStyle(.secondary)
      }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.07)))
        .contentShape(Rectangle())
    }.buttonStyle(.plain)
  }
}

struct ExecutionMessageView: View {
  @Bindable var store: WorkspaceStore
  let run: AgentRun
  @State private var expanded = false
  @State private var copied = false

  var body: some View {
    VStack(alignment: .leading, spacing: 23) {
      FileAttachmentsView(store: store, files: store.library.runFiles[run.id] ?? [])
      if let images = store.library.runImages[run.id], !images.isEmpty {
        ImageAttachmentsView(store: store, images: images)
      }
      HStack {
        Spacer(minLength: 35)
        ConversationSearchText(
          store.library.notes[run.id].flatMap { $0.isEmpty ? nil : $0 } ?? store.library.runFiles[run.id]?.first?.name ?? (store.library.runImages[run.id]?.isEmpty == false ? "图片" : run.title),
          id: .init(run: run.id, part: "prompt")
        )
        .appFont(size: 14).textSelection(.enabled).padding(.horizontal, 17).padding(
          .vertical, 12
        )
        .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
      }
      VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 9) {
          Image(systemName: "sparkle").appFont(size: 18)
          Text("ShipiOS").appFont(size: 13, weight: .semibold)
          Text(run.kind == "chat" ? (run.request["model"].text ?? "模型") : "本地执行").appFont(.caption)
            .foregroundStyle(.tertiary)
          Spacer()
          Text(run.date, style: .time).appFont(.caption).foregroundStyle(.tertiary)
        }
        if run.kind != "chat" {
          DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
              Text(
                run.kind == "doctor"
                  ? "xcodebuild -version"
                  : "xcodebuild · \(run.request["scheme"].text ?? "") · \(run.request["configuration"].text ?? "Debug")"
              )
              .appFont(.caption, design: .monospaced).textSelection(.enabled)
              if run.id == store.selection {
                ForEach(store.events) { event in
                  Label(
                    event.title,
                    systemImage: event.kind == "run.completed" ? "checkmark" : "circle.dotted"
                  )
                  .appFont(.caption).foregroundStyle(.secondary)
                }
              }
              Button("查看执行详情") { store.showDetails("artifacts", run: run) }.appFont(.caption)
                .buttonStyle(.plain)
            }.padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
          } label: {
            HStack {
              HStack {
                Image(systemName: run.kind == "doctor" ? "stethoscope" : "terminal")
                ConversationSearchText(run.title, id: .init(run: run.id, part: "operation"))
              }
              Spacer()
              StatusLabel(run: run).appFont(.caption)
            }.appFont(size: 12)
          }.padding(12).background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.primary.opacity(0.06)))
        }
        if run.kind == "chat" {
          if run.request["mode"].text == ChatMode.goal.rawValue {
            Label(
              "目标执行 · 第 \(run.request["goal_iteration"].int ?? 1)/\(run.request["goal_max_iterations"].int ?? 1) 轮",
              systemImage: ChatMode.goal.icon
            ).appFont(.caption, weight: .medium).foregroundStyle(.secondary)
          }
          ChatResponseView(store: store, run: run)
          if run.isActive, let status = run.result?["codex_runtime_status"].text,
            !status.isEmpty {
            Label(status, systemImage: "arrow.clockwise")
              .appFont(.caption).foregroundStyle(.secondary)
              .accessibilityLabel("Codex 运行状态：\(status)")
          }
          if run.isActive { ProgressView().controlSize(.small).accessibilityLabel("正在生成回复") }
          if let message = run.result?["message"].text {
            ConversationSearchText(message, id: .init(run: run.id, part: "error")).appFont(.callout)
              .foregroundStyle(.red).textSelection(.enabled)
          }
          if ["cancelled", "interrupted"].contains(run.status) {
            ConversationSearchText("回复已停止，已保留收到的内容。", id: .init(run: run.id, part: "stopped"))
              .appFont(.caption).foregroundStyle(.secondary)
          }
          if run.request["mode"].text == ChatMode.plan.rawValue, run.status == "succeeded" {
            HStack(spacing: 12) {
              Label("计划已生成", systemImage: ChatMode.plan.icon)
                .appFont(.caption, weight: .medium)
              Spacer()
              Button("按计划继续") { store.continueFromPlan(run) }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(!store.canStartChat)
            }.padding(12).background(
              .tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
              .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.tint.opacity(0.16)))
          }
        } else {
          ConversationSearchText(run.displaySummary, id: .init(run: run.id, part: "summary"))
            .appFont(size: 14).lineSpacing(5).textSelection(.enabled)
        }
        if run.kind == "doctor", let output = run.result?["command"]["stdout"].text, !output.isEmpty
        {
          ConversationSearchText(
            output.trimmingCharacters(in: .whitespacesAndNewlines),
            id: .init(run: run.id, part: "output")
          ).appFont(
            .caption, design: .monospaced
          ).foregroundStyle(.secondary).textSelection(.enabled)
        }
        if let first = run.result?["command"]["diagnostics"].items.first {
          ConversationSearchText(
            first["message"].text ?? "", id: .init(run: run.id, part: "diagnostic")
          ).appFont(.callout).foregroundStyle(.secondary).lineLimit(store.showingFind ? nil : 4)
            .textSelection(.enabled)
        }
        if !run.isActive {
          HStack(spacing: 16) {
            Button {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(
                run.kind == "chat" ? (run.result?["response"].text ?? "") : run.displaySummary,
                forType: .string)
              copied = true
            } label: {
              Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }.help(copied ? "已复制" : "复制结果")
              .accessibilityLabel(copied ? "已复制回复" : "复制完整回复")
            Button {
              store.selection = run.id
              Task { await store.rerun() }
            } label: {
              Image(systemName: "arrow.clockwise")
            }.disabled(run.kind == "chat" ? !store.canStartChat : !store.canStart).help("重新执行")
            Button {
              store.forkConversation(through: run.id)
            } label: {
              Image(systemName: "arrow.triangle.branch")
            }.disabled(!store.canForkConversation).help("从此处分叉到新任务")
              .accessibilityLabel("从此处分叉到新任务")
            if run.kind != "chat" {
              Button("查看日志") { store.showDetails("logs", run: run) }
              Button("诊断") { store.showDetails("diagnostics", run: run) }
            }
          }.buttonStyle(.plain).appFont(.caption).foregroundStyle(.secondary)
        }
      }
    }.task(id: copied) {
      guard copied else { return }
      try? await Task.sleep(for: .seconds(2))
      if !Task.isCancelled { copied = false }
    }
  }
}
