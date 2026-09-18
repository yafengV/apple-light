import AppKit
import Observation
import SwiftTerm

@MainActor @Observable
final class TerminalSession {
  let id = UUID()
  let root: URL
  private(set) var status: TerminalStatus = .running
  private(set) var title = "zsh"
  @ObservationIgnored let view: SessionTerminalView
  @ObservationIgnored private let delegate = TerminalSessionDelegate()

  init(root: URL) {
    self.root = root
    view = SessionTerminalView(frame: NSRect(x: 0, y: 0, width: 700, height: 240))
    view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    view.nativeBackgroundColor = .textBackgroundColor
    view.nativeForegroundColor = .textColor
    view.optionAsMetaKey = true
    delegate.session = self
    view.processDelegate = delegate
    view.startProcess(executable: "/bin/zsh", args: ["-f"], environment: [
      "PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
      "HOME=\(NSHomeDirectory())", "TMPDIR=\(NSTemporaryDirectory())", "LANG=en_US.UTF-8",
      "TERM=xterm-256color", "COLORTERM=truecolor", "PS1=%~ %# ",
    ], currentDirectory: root.path)
    if !view.process.running { status = .launchFailed }
  }

  func stop() {
    // SwiftTerm retains an exited shell's old PID. Never signal that stale PID.
    guard view.process.running else { return }
    status = .stopped
    let pid = view.process.shellPid
    let foreground = tcgetpgrp(view.process.childfd)
    if foreground > 0, foreground != pid, foreground != getpgrp() { kill(-foreground, SIGHUP) }
    if pid > 0 { kill(-pid, SIGHUP) }
    view.terminate()
    // terminate() cancels SwiftTerm's exit monitor; reap our child separately.
    if pid > 0 {
      Task.detached(priority: .utility) {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
      }
    }
  }
  fileprivate func ended(_ code: Int32?) {
    if status != .stopped { status = .processExit(code) }
  }
  fileprivate func updateTitle(_ value: String) {
    let cleaned = value.components(separatedBy: .controlCharacters).joined().trimmingCharacters(in: .whitespaces)
    title = cleaned.isEmpty ? "zsh" : String(cleaned.prefix(120))
  }
}

private final class TerminalSessionDelegate: NSObject, LocalProcessTerminalViewDelegate {
  weak var session: TerminalSession?
  func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
  func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
  func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
    Task { @MainActor [weak session] in session?.updateTitle(title) }
  }
  func processTerminated(source: TerminalView, exitCode: Int32?) {
    Task { @MainActor [weak session] in session?.ended(exitCode) }
  }
}
