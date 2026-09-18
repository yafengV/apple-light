import SwiftUI

/// Each presenting window owns the draft and target ID for its entire lifetime.
struct TaskRenameDialog: View {
  let initialTitle: String
  let save: (String) throws -> Void
  let close: () -> Void
  @State private var title = ""
  @State private var error: String?
  @FocusState private var focus: Field?
  private enum Field: CaseIterable { case name, cancel, save }
  private var valid: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        Color.black.opacity(0.3).contentShape(Rectangle())
          .onTapGesture(perform: close).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 16) {
          HStack {
            Text("重命名任务").font(.system(size: 17, weight: .semibold))
              .accessibilityAddTraits(.isHeader)
            Spacer()
            Button(action: close) { Image(systemName: "xmark") }
              .buttonStyle(.plain).accessibilityLabel("关闭重命名")
          }
          Text("使用简短、易于识别的名称").foregroundStyle(.secondary)
          TextField("添加名称…", text: $title)
            .textFieldStyle(.roundedBorder).focused($focus, equals: .name)
            .accessibilityLabel("任务名称").onSubmit(submit)
          if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
          HStack {
            Spacer()
            Button("取消", action: close).settingsActionFocus($focus, equals: .cancel, activate: close)
            Button("保存", action: submit).buttonStyle(.borderedProminent)
              .settingsActionFocus($focus, equals: .save, activate: submit).disabled(!valid)
          }
        }
        .padding(24).frame(width: min(440, geometry.size.width * 0.92), alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
        .accessibilityElement(children: .contain).accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("task-rename-dialog")
        .background(RenameDialogKeyboardBridge(onReady: { focus = .name }) { key in
          switch key {
          case .cancel: close()
          case .submit: if focus == .cancel { close() } else { submit() }
          case .tab(let reverse):
            let fields: [Field] = valid ? [.name, .cancel, .save] : [.name, .cancel]
            let index = fields.firstIndex(of: focus ?? .name) ?? 0
            focus = fields[(index + (reverse ? fields.count - 1 : 1)) % fields.count]
          }
        }.frame(width: 0, height: 0))
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }.onAppear { title = initialTitle }
  }

  private func submit() {
    guard valid else { focus = .name; return }
    do { try save(title); close() }
    catch { self.error = error.localizedDescription }
  }
}

private struct TaskRenameActiveKey: FocusedValueKey { typealias Value = Bool }
extension FocusedValues {
  var taskRenameActive: Bool? {
    get { self[TaskRenameActiveKey.self] }
    set { self[TaskRenameActiveKey.self] = newValue }
  }
}
