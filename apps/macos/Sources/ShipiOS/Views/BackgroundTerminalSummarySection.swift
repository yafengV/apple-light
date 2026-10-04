import SwiftUI

struct BackgroundTerminalSummarySection: View {
  let terminals: [CodexBackgroundTerminal]
  let cleaning: UUID?
  let open: (UUID) -> Void
  let clean: (UUID) async -> Void
  @State private var hovered: UUID?
  private enum Action: Hashable {
    case open(UUID), stop(UUID)
    var terminalID: UUID {
      switch self { case .open(let id), .stop(let id): id }
    }
  }
  @FocusState private var focused: Action?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("后台任务").appFont(.headline)
        Text(terminals.count.formatted()).appFont(.caption).foregroundStyle(.secondary)
      }
      ForEach(terminals) { terminal in
        HStack(spacing: 6) {
          Button { open(terminal.id) } label: {
            HStack(spacing: 8) {
              Image(systemName: "terminal").foregroundStyle(.secondary)
              Text(terminal.title).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            }.contentShape(Rectangle())
          }.buttonStyle(.plain).focused($focused, equals: .open(terminal.id))
            .help(terminal.title).accessibilityLabel("打开后台终端输出：\(terminal.title)")
          Button { Task { await clean(terminal.id) } } label: {
            if cleaning == terminal.id { ProgressView().controlSize(.small) }
            else { Image(systemName: "xmark") }
          }.buttonStyle(.plain)
            .focused($focused, equals: .stop(terminal.id))
            .disabled(cleaning != nil)
            .opacity(hovered == terminal.id || focused?.terminalID == terminal.id || cleaning != nil ? 1 : 0)
            .help("停止所有后台终端").accessibilityLabel("停止所有后台终端")
        }.appFont(.callout).padding(.vertical, 3)
          .onHover { hovered = $0 ? terminal.id : (hovered == terminal.id ? nil : hovered) }
      }
    }
  }
}
