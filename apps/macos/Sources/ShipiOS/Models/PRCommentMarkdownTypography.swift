import AppKit

/// Metrics from the Electron small Markdown stylesheet, resolved against the
/// selected content font. Paragraph margins collapse instead of adding.
struct PRCommentMarkdownTypography {
  let font: NSFont
  var size: CGFloat { font.pointSize }
  var space: CGFloat { size / 4 }
  var lineHeight: CGFloat { size * 1.625 }
  func headingSize(_ level: Int) -> CGFloat {
    size * (level == 1 ? 1.5 : level == 2 ? 1.25 : level == 3 ? 1.125 : 1)
  }
  func headingLineHeight(_ level: Int) -> CGFloat {
    switch level { case 1: space * 8; case 2, 3: space * 7; case 4: space * 6; default: lineHeight }
  }
  enum Container { case root, quote, list, item }
  func margins(_ blocks: [MessageBlock], at index: Int, in container: Container) -> (top: CGFloat, bottom: CGFloat) {
    let kind = blocks[index].kind
    var top: CGFloat = 0, bottom: CGFloat = 0
    switch kind {
    case .paragraph: bottom = container == .quote || container == .item ? 0 : space
    case .heading(let level):
      if level <= 4 { top = space * 4 }
      bottom = level == 1 ? space * 2 : level == 2 || level == 3 ? space : 0
    case .quote: bottom = space * 2
    case .code: top = space * 5; bottom = top
    case .table: top = space * 4
    default: break
    }
    if container == .root, case .paragraph = kind, index > 0 {
      top = space * 2
      if case .paragraph = blocks[index - 1].kind { top = space * 4; bottom = top }
      if case .heading(let level) = blocks[index - 1].kind, level <= 3 { top = 0 }
    }
    if container == .item, case .paragraph = kind, index > 0, case .paragraph = blocks[index - 1].kind { top = space * 4 }
    if index == 0 { top = 0 }
    if container == .item, index == 0, !isLargeHeading(kind) { bottom = 0 }
    if index == blocks.count - 1 { bottom = 0 }
    return (top, bottom)
  }
  func gap(_ blocks: [MessageBlock], before index: Int, in container: Container) -> CGFloat {
    guard index > 0 else { return margins(blocks, at: index, in: container).top }
    return max(margins(blocks, at: index - 1, in: container).bottom, margins(blocks, at: index, in: container).top)
  }
  static func listMarker(_ marker: String, depth: Int) -> String {
    marker == "•" ? depth > 2 ? "■" : depth > 1 ? "◦" : "•" : marker
  }
  private func isLargeHeading(_ kind: MessageBlock.Kind) -> Bool {
    if case .heading(let level) = kind { return level <= 3 }; return false
  }
}
