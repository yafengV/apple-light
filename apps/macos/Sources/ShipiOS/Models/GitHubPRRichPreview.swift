import Foundation

enum GitHubPRRichPreview {
  private static let markdownExtensions: Set<String> = ["markdown", "md", "mdown", "mdx", "mkd"]

  static func supportsMarkdown(_ file: GitHubPRCodeFile) -> Bool {
    file.kind != .deleted && !file.binary
      && markdownExtensions.contains((file.path as NSString).pathExtension.lowercased())
  }
}
