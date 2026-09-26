import SwiftUI

struct CodexElicitationView: View {
  @Bindable var store: WorkspaceStore
  let run: AgentRun
  let request: CodexElicitationRequest
  @State private var drafts: [String: String] = [:]
  @State private var toggles: [String: Bool] = [:]
  @State private var selections: [String: Int] = [:]

  private enum FieldValue { case omitted, value(JSONValue), invalid }
  private var pending: Bool {
    run.isActive && request.status == .awaiting
      && store.codexPendingElicitations[request.id] != nil
  }

  private func fieldValue(_ field: CodexElicitationField) -> FieldValue {
    let raw = drafts[field.id] ?? ""
    switch field.kind {
    case .text:
      return raw.isEmpty && !field.required ? .omitted : .value(.string(raw))
    case .integer:
      if raw.isEmpty && !field.required { return .omitted }
      guard let value = Int(raw), abs(Double(value)) <= 9_007_199_254_740_991 else { return .invalid }
      return .value(.number(Double(value)))
    case .number:
      if raw.isEmpty && !field.required { return .omitted }
      guard let value = Double(raw), value.isFinite else { return .invalid }
      return .value(.number(value))
    case .boolean:
      return .value(.bool(toggles[field.id] ?? false))
    case .choice:
      let index = selections[field.id] ?? 0
      guard field.choices.indices.contains(index) else { return .invalid }
      return .value(field.choices[index])
    case .json:
      if raw.isEmpty && !field.required { return .omitted }
      guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
      else { return .invalid }
      return .value(value)
    }
  }

  private var content: JSONValue? {
    var values: [String: JSONValue] = [:]
    for field in request.fields {
      switch fieldValue(field) {
      case .omitted: break
      case .value(let value): values[field.id] = value
      case .invalid: return nil
      }
    }
    let content = JSONValue.object(values)
    return request.validContent(content) ? content : nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Image(systemName: "list.bullet.rectangle")
        Text("MCP 表单 · \(request.serverName)").appFont(.headline)
        Spacer()
        Text(statusLabel).appFont(.caption).foregroundStyle(.secondary)
      }
      Text(request.message).appFont(.body).textSelection(.enabled)
      if pending {
        ForEach(request.fields) { field in
          VStack(alignment: .leading, spacing: 5) {
            if field.kind != .boolean {
              Text(field.title + (field.required ? " *" : "")).appFont(.callout)
            }
            switch field.kind {
            case .boolean:
              Toggle(field.title, isOn: Binding(
                get: { toggles[field.id] ?? false },
                set: { toggles[field.id] = $0 }))
            case .choice:
              Picker(field.title, selection: Binding(
                get: { selections[field.id] ?? 0 },
                set: { selections[field.id] = $0 })) {
                ForEach(field.choices.indices, id: \.self) { index in
                  Text(field.choices[index].text ?? field.choices[index].pretty).tag(index)
                }
              }.labelsHidden()
            case .json:
              TextEditor(text: binding(for: field.id))
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 90, maxHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.secondary.opacity(0.25)))
            default:
              if field.secret {
                SecureField(field.title, text: binding(for: field.id))
              } else {
                TextField(field.title, text: binding(for: field.id))
              }
            }
            if !field.description.isEmpty {
              Text(field.description).appFont(.caption).foregroundStyle(.secondary)
            }
          }
        }
        HStack {
          Button("拒绝") { store.submitCodexElicitation(request.id, accepted: false, content: nil) }
          Spacer()
          Button("提交") {
            store.submitCodexElicitation(request.id, accepted: true, content: content)
          }
          .buttonStyle(.borderedProminent)
          .disabled(content == nil)
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
    case .awaiting: pending ? "等待填写" : "已结束"
    case .accepted: "已提交"
    case .declined: "已拒绝"
    case .cancelled: "已取消"
    case .expired: "已过期"
    }
  }

  private func binding(for id: String) -> Binding<String> {
    Binding(get: { drafts[id] ?? "" }, set: { drafts[id] = $0 })
  }
}
