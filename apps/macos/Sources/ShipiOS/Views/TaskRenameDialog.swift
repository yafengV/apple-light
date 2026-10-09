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
  @FocusState private var focus: RenameDialogField?
  @Environment(\.appAppearance) private var appearance
  private var valid: Bool { configuration.allowsEmpty || !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        Color.black.opacity(RenameDialogMetrics.overlayOpacity).contentShape(Rectangle())
          .onTapGesture(perform: close).accessibilityHidden(true)
        RenameDialogSurface(availableWidth: geometry.size.width) {
          RenameDialogHeader(title: configuration.title, subtitle: configuration.subtitle)
        } input: {
          VStack(alignment: .leading, spacing: 8) {
            TextField(configuration.placeholder, text: $title)
              .textFieldStyle(.plain).appFont(size: RenameDialogMetrics.inputFont)
              .padding(.horizontal, RenameDialogMetrics.inputPadding + RenameDialogMetrics.borderWidth)
              .frame(height: RenameDialogMetrics.inputHeight)
              .background(appearance.resolvedColors["controlBackground"].color,
                in: RoundedRectangle(cornerRadius: RenameDialogMetrics.inputRadius, style: .continuous))
              .overlay {
                RoundedRectangle(cornerRadius: RenameDialogMetrics.inputRadius, style: .continuous)
                  .strokeBorder(appearance.resolvedColors[focus == .name ? "borderFocus" : "borderHeavy"].color, lineWidth: 1)
                  .allowsHitTesting(false)
              }
              .focused($focus, equals: .name).accessibilityLabel(configuration.ariaLabel).onSubmit(submit)
            if let error { Text(error).appFont(size: 13).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
          }
        } footer: {
          HStack(spacing: RenameDialogMetrics.buttonGap) {
            Spacer(minLength: 0)
            Button("取消", action: close)
              .buttonStyle(RenameDialogButtonStyle(role: .outline, focused: focus == .cancel))
              .renameDialogActionFocus($focus, equals: .cancel, activate: close)
            Button("保存", action: submit)
              .buttonStyle(RenameDialogButtonStyle(role: .primary, focused: focus == .save))
              .renameDialogActionFocus($focus, equals: .save, activate: submit).disabled(!valid)
          }
        } close: {
          Button(action: close) { Image(systemName: "xmark").font(.system(size: 12)).frame(width: 16, height: 16) }
            .buttonStyle(RenameDialogButtonStyle(role: .close, focused: focus == .close))
            .renameDialogActionFocus($focus, equals: .close, activate: close).accessibilityLabel("关闭重命名")
        }
        .accessibilityElement(children: .contain).accessibilityAddTraits(.isModal)
        .accessibilityIdentifier(configuration.identifier)
        .background(RenameDialogKeyboardBridge(onReady: { focus = .name }) { key in
          switch key {
          case .cancel: close()
          case .submit: if focus?.closesOnEnter == true { close() } else { submit() }
          case .tab(let reverse):
            focus = RenameDialogField.next(after: focus, valid: valid, reverse: reverse)
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
