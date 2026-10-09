import SwiftUI

/// Each presenting window owns the draft and target ID for its entire lifetime.
struct TaskRenameDialog: View {
  let initialTitle: String
  let save: (String) throws -> Void
  let close: () -> Void
  var configuration = Configuration.task
  struct Configuration {
    let title: String
    let subtitle: String
    let placeholder: String
    let ariaLabel: String
    let identifier: String
    var allowsEmpty = false
    static let task = Self(title: "重命名任务", subtitle: "使用简短、易于识别的名称",
      placeholder: "添加名称…", ariaLabel: "任务名称", identifier: "task-rename-dialog")
    static func browser(defaultTitle: String) -> Self {
      Self(title: "重命名标签页", subtitle: "留空即可使用默认标题", placeholder: defaultTitle,
        ariaLabel: "标签页标题", identifier: "pinned-browser-rename-dialog", allowsEmpty: true)
    }
  }
  @State private var title = ""
  @State private var error: String?
  @FocusState private var focus: Field?
  private enum Field: CaseIterable { case name, cancel, save }
  private var valid: Bool { configuration.allowsEmpty || !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        Color.black.opacity(0.3).contentShape(Rectangle())
          .onTapGesture(perform: close).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 16) {
          HStack {
            Text(configuration.title).font(.system(size: 17, weight: .semibold))
              .accessibilityAddTraits(.isHeader)
            Spacer()
            Button(action: close) { Image(systemName: "xmark") }
              .buttonStyle(.plain).accessibilityLabel("关闭重命名")
          }
          Text(configuration.subtitle).foregroundStyle(.secondary)
          TextField(configuration.placeholder, text: $title)
            .textFieldStyle(.roundedBorder).focused($focus, equals: .name)
            .accessibilityLabel(configuration.ariaLabel).onSubmit(submit)
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
        .accessibilityIdentifier(configuration.identifier)
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
