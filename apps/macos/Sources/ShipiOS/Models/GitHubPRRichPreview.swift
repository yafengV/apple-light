import Foundation

enum GitHubPRRichPreview {
  enum BinaryKind: Equatable, Sendable { case image, svg, pdf }

  struct Binary: Equatable, Sendable {
    let kind: BinaryKind
    let before: Data?
    let after: Data?
  }

  private static let markdownExtensions: Set<String> = ["markdown", "md", "mdown", "mdx", "mkd"]
  private static let imageExtensions: Set<String> = ["avif", "bmp", "gif", "ico", "jpeg", "jpg", "png", "tif", "tiff", "webp"]

  static func supportsMarkdown(_ file: GitHubPRCodeFile) -> Bool {
    file.kind != .deleted && !file.binary
      && markdownExtensions.contains((file.path as NSString).pathExtension.lowercased())
  }

  static func binaryKind(_ file: GitHubPRCodeFile, richPreviewEnabled: Bool) -> BinaryKind? {
    let ext = (file.path as NSString).pathExtension.lowercased()
    if imageExtensions.contains(ext) { return .image }
    if ext == "svg", richPreviewEnabled { return .svg }
    if ext == "pdf" { return .pdf }
    return nil
  }
}
