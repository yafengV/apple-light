import SwiftUI

struct ComposerCommandsView: View {
  @Bindable var store: WorkspaceStore
  @Binding var selection: ComposerCommandSelection
  var enabled: Set<ComposerCommand>?
  var accept: ((ComposerCommand) -> Void)?

  var body: some View {
    VStack(spacing: 0) {
      ScrollViewReader { reader in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(selection.matches) { command in
              Button {
                if let accept { accept(command) } else { store.selectComposerCommand(command) }
              } label: {
                HStack {
                  Text(command.token).appFont(.caption, design: .monospaced)
                  Spacer()
                  Text(command.title).appFont(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 9).frame(height: 32).contentShape(Rectangle())
                  .background(
                    selection.selected == command ? Color.primary.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 5))
              }.buttonStyle(.plain).disabled(!(enabled ?? store.enabledComposerCommands).contains(command))
                .accessibilityAddTraits(selection.selected == command ? .isSelected : [])
                .onHover { if $0 { selection.highlight(command) } }
                .id(command)
            }
          }.padding(6)
        }.frame(height: min(CGFloat(selection.matches.count) * 34 + 10, 214))
          .onChange(of: selection.selected) { _, command in
            if let command { reader.scrollTo(command) }
          }
      }
      Divider()
      HStack {
        Text("↑↓ 选择 · ↵ / Tab 确认")
        Spacer()
        Text("esc 关闭")
      }.appFont(size: 10).foregroundStyle(.secondary).padding(8)
    }.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
      .accessibilityLabel("斜杠命令")
  }
}

struct ComposerQueueView: View {
  @Bindable var store: WorkspaceStore
  var body: some View {
    let messages = store.library.queuedMessages.filter { $0.taskID == store.selectedTask?.id }
    VStack(spacing: 5) {
      ForEach(messages) { message in
        HStack(spacing: 10) {
          Image(systemName: "text.line.first.and.arrowtriangle.forward")
          if message.mode == .plan {
            Label("计划", systemImage: ChatMode.plan.icon).foregroundStyle(.secondary)
          } else if message.mode == .goal {
            Label("目标", systemImage: ChatMode.goal.icon).foregroundStyle(.secondary)
          }
          Text(message.text.isEmpty ? "附件消息" : message.text).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
          if !message.files.isEmpty {
            Label("\(message.files.count)", systemImage: "doc.text")
              .help("\(message.files.count) 个文件")
          }
          if !message.images.isEmpty {
            Label("\(message.images.count)", systemImage: "photo")
              .help("\(message.images.count) 张图片")
          }
          Menu {
            Button("编辑") { store.editQueuedMessage(message) }
            Button("上移") { store.moveQueuedMessage(message, offset: -1) }
            Button("下移") { store.moveQueuedMessage(message, offset: 1) }
            Button("立即发送") { Task { await store.sendQueuedMessage(message) } }.disabled(
              !store.canStartChat)
            Button("删除", role: .destructive) { store.removeQueuedMessage(message.id) }
          } label: {
            Image(systemName: "ellipsis")
          }.menuStyle(.borderlessButton).fixedSize()
        }.appFont(.caption).padding(10).background(
          .primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
      }
    }
  }
}
