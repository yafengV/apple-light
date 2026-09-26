import SwiftUI

struct CodexQuestionView: View {
  @Bindable var store: WorkspaceStore
  let run: AgentRun
  let request: CodexQuestionRequest
  @State private var selections: [String: String] = [:]
  @State private var drafts: [String: String] = [:]

  private var pending: Bool {
    run.isActive && request.status == .awaiting && store.codexPendingQuestions[request.id] != nil
  }

  private var answers: [String: [String]] {
    var result: [String: [String]] = [:]
    for question in request.questions {
      let selected = selections[question.id]
      let value = question.options == nil || selected == "__other__"
        ? drafts[question.id] : selected
      if let value { result[question.id] = [value.trimmingCharacters(in: .whitespacesAndNewlines)] }
    }
    return result
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Image(systemName: "questionmark.bubble")
        Text("Codex 提问").appFont(.headline)
        Spacer()
        Text(statusLabel).foregroundStyle(.secondary).appFont(.caption)
      }
      ForEach(request.questions) { question in
        VStack(alignment: .leading, spacing: 7) {
          if !question.header.isEmpty {
            Text(question.header).appFont(.caption).foregroundStyle(.secondary)
          }
          Text(question.question).appFont(.body).textSelection(.enabled)
          if pending {
            if let options = question.options {
              ForEach(options, id: \.label) { option in
                Button {
                  selections[question.id] = option.label
                } label: {
                  HStack(alignment: .top, spacing: 8) {
                    Image(systemName: selections[question.id] == option.label ? "largecircle.fill.circle" : "circle")
                    VStack(alignment: .leading, spacing: 2) {
                      Text(option.label)
                      if !option.description.isEmpty {
                        Text(option.description).appFont(.caption).foregroundStyle(.secondary)
                      }
                    }
                    Spacer()
                  }
                }.buttonStyle(.plain)
              }
              if question.isOther {
                Button {
                  selections[question.id] = "__other__"
                } label: {
                  Label("其他", systemImage: selections[question.id] == "__other__"
                    ? "largecircle.fill.circle" : "circle")
                }.buttonStyle(.plain)
              }
            }
            if question.options == nil || (question.isOther && selections[question.id] == "__other__") {
              if question.isSecret {
                SecureField("填写回答", text: binding(for: question.id))
              } else {
                TextField("填写回答", text: binding(for: question.id))
              }
            }
          }
        }
      }
      if pending {
        HStack {
          Spacer()
          Button("提交回答") {
            let submitted = answers
            drafts.removeAll()
            selections.removeAll()
            Task { await store.answerCodexQuestion(request.id, answers: submitted) }
          }
          .buttonStyle(.borderedProminent)
          .disabled(!request.validAnswers(answers))
        }
      }
    }
    .padding(12)
    .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(
      pending ? Color.accentColor.opacity(0.5) : .primary.opacity(0.06)))
  }

  private var statusLabel: String {
    switch request.status {
    case .awaiting: pending ? "等待回答" : "已结束"
    case .answered: "已回答"
    case .cancelled: "已取消"
    case .expired: "已过期"
    }
  }

  private func binding(for id: String) -> Binding<String> {
    Binding(get: { drafts[id] ?? "" }, set: { drafts[id] = $0 })
  }
}
