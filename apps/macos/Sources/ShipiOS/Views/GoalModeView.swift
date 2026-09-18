import SwiftUI

struct GoalEditorView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var objective: String
  @State private var criteria: String
  @State private var maxIterations: Int
  let onSave: (GoalDefinition) -> Bool

  init(initial: GoalDefinition?, onSave: @escaping (GoalDefinition) -> Bool) {
    _objective = State(initialValue: initial?.objective ?? "")
    _criteria = State(initialValue: initial?.successCriteria.joined(separator: "\n") ?? "")
    _maxIterations = State(initialValue: initial?.maxIterations ?? 5)
    self.onSave = onSave
  }

  private var successCriteria: [String] {
    criteria.components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      VStack(alignment: .leading, spacing: 5) {
        Text("目标模式").appFont(.title2, weight: .semibold)
        Text("定义结果和可核验的成功标准。ShipiOS 会持续推进，并在完成、需要你处理或达到轮次上限时停下。")
          .appFont(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      VStack(alignment: .leading, spacing: 7) {
        Text("目标").appFont(.caption, weight: .semibold)
        TextField("要完成什么结果？", text: $objective, axis: .vertical)
          .textFieldStyle(.roundedBorder).lineLimit(2...5)
      }
      VStack(alignment: .leading, spacing: 7) {
        Text("成功标准").appFont(.caption, weight: .semibold)
        Text("每行一条，写成可以检查的结果。")
          .appFont(.caption).foregroundStyle(.secondary)
        TextEditor(text: $criteria).appFont(size: 13)
          .scrollContentBackground(.hidden).padding(8).frame(minHeight: 110)
          .background(.background, in: RoundedRectangle(cornerRadius: 8))
          .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.14)))
      }
      Stepper("最多连续执行 \(maxIterations) 轮", value: $maxIterations, in: 1...10)
        .appFont(.callout)
      HStack {
        Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button("保存目标") {
          if onSave(GoalDefinition(
            objective: objective, successCriteria: successCriteria,
            maxIterations: maxIterations))
          { dismiss() }
        }
        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        .disabled(
          objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || successCriteria.isEmpty)
      }
    }.padding(24).frame(width: 510)
  }
}

struct GoalStatusCard: View {
  @Bindable var store: WorkspaceStore
  let taskID: String?
  let onEdit: () -> Void

  private var session: GoalSession? { store.goalSession(for: taskID) }
  private var definition: GoalDefinition? {
    session?.definition ?? (taskID == nil ? store.pendingGoal : nil)
  }

  var body: some View {
    if let definition {
      VStack(alignment: .leading, spacing: 9) {
        HStack(spacing: 8) {
          Image(systemName: ChatMode.goal.icon).foregroundStyle(.tint)
          Text(definition.objective).appFont(.callout, weight: .semibold).lineLimit(2)
          Spacer()
          Text(session?.status.title ?? "待开始").appFont(.caption).foregroundStyle(.secondary)
          if let session {
            Text("\(session.iteration)/\(definition.maxIterations)")
              .appFont(.caption, design: .monospaced).foregroundStyle(.tertiary)
          }
        }
        DisclosureGroup("成功标准（\(definition.successCriteria.count)）") {
          VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(definition.successCriteria.enumerated()), id: \.offset) { index, value in
              Text("\(index + 1). \(value)").appFont(.caption).foregroundStyle(.secondary)
            }
          }.padding(.top, 5).frame(maxWidth: .infinity, alignment: .leading)
        }.appFont(.caption)
        HStack(spacing: 12) {
          Button("编辑", action: onEdit).buttonStyle(.plain)
            .disabled(taskID.map(store.taskWindowOwnsActiveRun) == true)
          if let taskID, let session {
            switch session.status {
            case .active:
              Button("暂停") { store.pauseGoal(taskID) }.buttonStyle(.plain)
            case .paused, .completed:
              Button(session.status == .completed ? "重新打开并继续" : "继续目标") {
                Task { await store.resumeGoal(taskID) }
              }.buttonStyle(.plain).disabled(!store.canStartChat(taskID: taskID))
            }
            if session.status != .completed {
              Button("标记完成") { store.completeGoal(taskID) }.buttonStyle(.plain)
            }
          } else {
            Button("移除") { store.clearPendingGoal() }.buttonStyle(.plain)
          }
        }.appFont(.caption).foregroundStyle(.secondary)
      }
      .padding(12).background(.tint.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))
      .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(.tint.opacity(0.16)))
    }
  }
}
