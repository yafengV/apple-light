import Foundation

struct TerminalFocusRequest: Equatable {
  let id = UUID()
  let scope: TerminalScope
  let sessionID: UUID?
  init(scope: TerminalScope, sessionID: UUID? = nil) {
    self.scope = scope
    self.sessionID = sessionID
  }
}

struct TerminalScope: Hashable, Sendable {
  let project: String
  let conversation: String
  init(root: URL, conversation: String) {
    project = GitBranchService.canonicalRoot(root).path
    self.conversation = conversation
  }
  var root: URL { URL(fileURLWithPath: project) }
}

enum TerminalStatus: Equatable {
  case running, exited(Int), signalled(Int), stopped, launchFailed
  var label: String {
    switch self {
    case .running: "运行中"
    case .exited(let code): "已结束 · 退出码 \(code)"
    case .signalled(let signal): "已结束 · 信号 \(signal)"
    case .stopped: "会话已结束"
    case .launchFailed: "无法启动终端"
    }
  }
  // The pinned SwiftTerm macOS forkpty backend reports raw waitpid status.
  static func processExit(_ status: Int32?) -> Self {
    guard let status else { return .launchFailed }
    let signal = Int(status & 0x7f)
    return signal == 0 ? .exited(Int((status >> 8) & 0xff)) : .signalled(signal)
  }
}
