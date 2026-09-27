import SwiftUI

/// A shell stays owned by its terminal tab while this pane is mounted or moved.
struct TerminalSessionPane: View {
  @Bindable var session: TerminalSession
  let focus: TerminalFocusRequest?
  let canFocus: (TerminalFocusRequest) -> Bool
  let restart: () -> Void
  var close: (() -> Void)?

  var body: some View {
    VStack(spacing: 0) {
      if let close {
        HStack {
          Text(session.displayTitle).appFont(.caption).foregroundStyle(.secondary).lineLimit(1)
          Spacer()
          if session.status == .running {
            Button { session.stop() } label: { Image(systemName: "stop") }
              .buttonStyle(.plain).help("结束此拆分终端").accessibilityLabel("结束拆分终端")
          }
          Button(action: restart) { Image(systemName: "arrow.clockwise") }
            .buttonStyle(.plain).help("重新打开拆分终端").accessibilityLabel("重新打开拆分终端")
          Button(action: close) { Image(systemName: "xmark") }
            .buttonStyle(.plain).help("关闭拆分终端").accessibilityLabel("关闭拆分终端")
        }.padding(.horizontal, 10).padding(.vertical, 7)
        Divider()
      }
      TerminalHost(session: session, focus: focus, canFocus: canFocus)
        .id(ObjectIdentifier(session))
      if session.status != .running {
        HStack {
          Text(session.status.label).appFont(.caption).foregroundStyle(.secondary)
          Spacer()
          Button("重新打开", action: restart).controlSize(.small)
        }.padding(.horizontal, 10).padding(.vertical, 6)
      }
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
