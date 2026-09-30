import SwiftUI

struct FileFindBar: View {
  @Bindable var finder: FileFindSession
  let workspace: DeveloperWorkspace
  @FocusState private var queryFocused: Bool

  init(workspace: DeveloperWorkspace) {
    self.workspace = workspace
    finder = workspace.fileFind
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Button { finder.isReplacing.toggle(); queryFocused = true } label: {
          Image(systemName: finder.isReplacing ? "chevron.down" : "chevron.right")
        }.help("查找与替换").accessibilityLabel("查找与替换")
        TextField("在文件中查找…", text: $finder.query)
          .textFieldStyle(.roundedBorder).focused($queryFocused)
          .accessibilityLabel("在文件中查找")
          .onSubmit { finder.move(1) }
          .onExitCommand { close() }
        Text(finder.countLabel).foregroundStyle(.secondary).monospacedDigit()
          .frame(minWidth: 55, alignment: .trailing)
        Button { finder.move(-1); queryFocused = true } label: { Image(systemName: "chevron.up") }
          .disabled(finder.matches.isEmpty).help("上一个匹配")
        Button { finder.move(1); queryFocused = true } label: { Image(systemName: "chevron.down") }
          .disabled(finder.matches.isEmpty).help("下一个匹配")
        Button(action: close) { Image(systemName: "xmark") }
          .help("关闭查找").accessibilityLabel("关闭查找")
      }
      HStack(spacing: 7) {
        optionButton("Aa", label: "区分大小写", enabled: finder.options.matchCase) {
          finder.options.matchCase.toggle()
        }
        optionButton("整词", label: "仅匹配完整单词", enabled: finder.options.wholeWord) {
          finder.options.wholeWord.toggle()
        }
        optionButton(".*", label: "正则表达式", enabled: finder.options.regularExpression) {
          finder.options.regularExpression.toggle()
        }
        Spacer()
      }
      if finder.isReplacing {
        HStack(spacing: 6) {
          TextField("替换为…", text: $finder.replacement)
            .textFieldStyle(.roundedBorder).accessibilityLabel("替换为")
            .onSubmit { finder.replaceCurrent() }
            .onExitCommand { close() }
          Button("替换") { finder.replaceCurrent() }
            .disabled(!canReplace)
          Button("全部替换") { finder.replaceAll() }
            .disabled(!canReplace)
        }
      }
      if let error = finder.error {
        Text(error).foregroundStyle(.orange).lineLimit(2)
      }
    }
    .buttonStyle(.plain).appFont(.caption)
    .padding(8).frame(width: 385)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.secondary.opacity(0.25)))
    .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
    .onAppear { queryFocused = true }
    .onChange(of: finder.focusRequest) { _, _ in queryFocused = true }
    .onChange(of: finder.query) { _, _ in finder.refresh(in: workspace.fileText, reveal: true) }
    .onChange(of: finder.options) { _, _ in finder.refresh(in: workspace.fileText, reveal: true) }
  }

  private var canReplace: Bool {
    !finder.matches.isEmpty && finder.error == nil && workspace.selectedFileEditor != nil
      && !workspace.fileLoading && workspace.fileError == nil
  }

  private func optionButton(_ title: String, label: String, enabled: Bool,
    action: @escaping () -> Void) -> some View {
    Button { action(); queryFocused = true } label: {
      Text(title).fontWeight(enabled ? .bold : .regular)
    }
      .padding(.horizontal, 5).padding(.vertical, 2)
      .background(enabled ? Color.accentColor.opacity(0.18) : .clear,
        in: RoundedRectangle(cornerRadius: 4))
      .accessibilityLabel(label).accessibilityAddTraits(enabled ? .isSelected : [])
      .help(label)
  }

  private func close() {
    finder.close()
    workspace.fileFocusRequest = UUID()
  }
}
