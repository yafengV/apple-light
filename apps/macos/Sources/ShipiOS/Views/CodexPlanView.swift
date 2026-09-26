import SwiftUI

struct CodexPlanView: View {
  let plan: CodexPlan

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      Label("计划", systemImage: "list.bullet.clipboard").appFont(.headline)
      if let explanation = plan.explanation, !explanation.isEmpty {
        Text(explanation).foregroundStyle(.secondary).appFont(.caption)
      }
      ForEach(Array(plan.steps.enumerated()), id: \.offset) { _, step in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Image(systemName: icon(for: step.status))
            .foregroundStyle(step.status == .completed ? Color.green : Color.secondary)
          Text(step.step).appFont(.body)
          Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(statusLabel(for: step.status))：\(step.step)")
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
  }

  private func icon(for status: CodexPlanStep.Status) -> String {
    switch status {
    case .pending: "circle"
    case .inProgress: "circle.dotted"
    case .completed: "checkmark.circle.fill"
    }
  }

  private func statusLabel(for status: CodexPlanStep.Status) -> String {
    switch status {
    case .pending: "待处理"
    case .inProgress: "进行中"
    case .completed: "已完成"
    }
  }
}
