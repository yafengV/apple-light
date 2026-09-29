import AppKit

@MainActor enum PullRequestCodeClipboard {
  @discardableResult static func copy(_ file: GitHubPRCodeFile, to board: NSPasteboard = .general) -> Bool {
    board.clearContents()
    return board.setString(file.headerRelativePath, forType: .string)
  }
}
