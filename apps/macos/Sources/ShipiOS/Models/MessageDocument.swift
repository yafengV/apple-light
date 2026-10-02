import Foundation
import Markdown

/// A value-only render tree; parsing can run away from the main actor while a reply streams.
struct MessageBlock: Identifiable, Sendable, Equatable {
  enum Kind: Sendable, Equatable {
    case paragraph
    case heading(Int)
    case code(String)
    case quote, list
    case item(String, Bool?)
    case table, rule
    case media(GitHubPRCommentMedia)
    case prImage(path: String, alt: String)
  }
  let id: String
  let kind: Kind
  var text = AttributedString()
  var source = ""
  var children: [MessageBlock] = []
  var rows: [[AttributedString]] = []
  var mediaRows: [[[MessageBlock]]] = []
  /// -1 = leading, 0 = center, 1 = trailing.
  var alignments: [Int] = []
}

enum MessageDocument {
  static func parse(_ source: String, githubMedia: Bool = false,
    prContext: GitHubPRMarkdownContext? = nil) -> [MessageBlock] {
    blocks(Document(parsing: source), prefix: "",
      githubMedia: githubMedia && GitHubPRCommentMedia.mightContainURL(source), prContext: prContext)
  }

  private static func blocks(_ markup: any Markup, prefix: String, githubMedia: Bool,
    prContext: GitHubPRMarkdownContext?) -> [MessageBlock] {
    markup.children.enumerated().flatMap { index, child -> [MessageBlock] in
      let id = prefix + "\(index)"
      if githubMedia || prContext != nil, let paragraph = child as? Paragraph {
        return paragraphBlocks(paragraph, id: id, prContext: prContext)
      }
      if githubMedia || prContext != nil, let heading = child as? Heading {
        let parts = inlineBlocks(heading, id: id, textKind: .heading(heading.level), prContext: prContext)
        if parts.contains(where: hasMedia) {
          return parts
        }
      }
      if githubMedia, let html = child as? HTMLBlock,
        let media = GitHubPRCommentMedia.html(html.rawHTML) {
        return [MessageBlock(id: id, kind: .media(media))]
      }
      return [block(child, id: id, githubMedia: githubMedia, prContext: prContext)]
    }
  }

  private static func block(_ markup: any Markup, id: String, githubMedia: Bool,
    prContext: GitHubPRMarkdownContext?) -> MessageBlock {
    switch markup {
    case let heading as Heading:
      return MessageBlock(id: id, kind: .heading(heading.level), text: inline(heading, prContext: prContext))
    case let code as CodeBlock:
      return MessageBlock(id: id, kind: .code(code.language ?? ""), source: code.code)
    case is BlockQuote:
      return MessageBlock(id: id, kind: .quote,
        children: blocks(markup, prefix: id + ".", githubMedia: githubMedia, prContext: prContext))
    case is UnorderedList, is OrderedList:
      let start = (markup as? OrderedList)?.startIndex
      let items = markup.children.enumerated().map { offset, child in
        let item = child as? ListItem
        return MessageBlock(
          id: id + ".\(offset)",
          kind: .item(
            start.map { "\($0 + UInt(offset))." } ?? "•", item?.checkbox.map { $0 == .checked }),
          children: blocks(child, prefix: id + ".\(offset).", githubMedia: githubMedia, prContext: prContext))
      }
      return MessageBlock(id: id, kind: .list, children: items)
    case let table as Markdown.Table:
      let rows =
        [Array(table.head.cells.map { inline($0, prContext: prContext) })]
        + table.body.rows.map { Array($0.cells.map { inline($0, prContext: prContext) }) }
      let richRows: [[[MessageBlock]]] = githubMedia || prContext != nil
        ? [table.head.cells.enumerated().map { column, cell in
            inlineBlocks(cell, id: "\(id).cell.0.\(column)", prContext: prContext)
          }] + table.body.rows.enumerated().map { row, item in
            item.cells.enumerated().map { column, cell in
              inlineBlocks(cell, id: "\(id).cell.\(row + 1).\(column)", prContext: prContext)
            }
          }
        : []
      let hasMedia = richRows.flatMap { $0 }.flatMap { $0 }.contains(where: hasMedia)
      return MessageBlock(
        id: id, kind: .table, rows: rows, mediaRows: hasMedia ? richRows : [],
        alignments: table.columnAlignments.map {
          switch $0 {
          case .center: 0
          case .right: 1
          default: -1
          }
        })
    case is ThematicBreak:
      return MessageBlock(id: id, kind: .rule)
    case let html as HTMLBlock:
      // Display source; model-provided HTML must never execute in the conversation.
      return MessageBlock(id: id, kind: .code("html"), source: html.rawHTML)
    default:
      return MessageBlock(id: id, kind: .paragraph, text: inline(markup, prContext: prContext))
    }
  }

  private enum InlinePart {
    case text(AttributedString)
    case media(GitHubPRCommentMedia)
    case prImage(path: String, alt: String)
  }

  private static func paragraphBlocks(_ paragraph: Paragraph, id: String,
    prContext: GitHubPRMarkdownContext?) -> [MessageBlock] {
    let raw = paragraph.format().trimmingCharacters(in: .whitespacesAndNewlines)
    if let url = GitHubPRCommentMedia.videoURL(raw) {
      return [MessageBlock(id: id, kind: .media(.init(url: url, kind: .video, alt: raw)))]
    }
    if paragraph.childCount == 1, let link = paragraph.children.first as? Markdown.Link,
      let destination = link.destination, let url = GitHubPRCommentMedia.videoURL(destination),
      link.plainText == destination {
      return [MessageBlock(id: id, kind: .media(.init(url: url, kind: .video, alt: link.plainText)))]
    }
    let result = inlineBlocks(paragraph, id: id, prContext: prContext)
    return result.contains(where: hasMedia)
      ? result : [MessageBlock(id: id, kind: .paragraph, text: inline(paragraph, prContext: prContext))]
  }

  private static func inlineBlocks(_ markup: any Markup, id: String,
    textKind: MessageBlock.Kind = .paragraph, prContext: GitHubPRMarkdownContext?) -> [MessageBlock] {
    var result: [MessageBlock] = []
    var pending = AttributedString()
    func flush() {
      guard !pending.characters.isEmpty else { return }
      result.append(MessageBlock(id: "\(id).\(result.count)", kind: textKind, text: pending))
      pending = AttributedString()
    }
    for part in inlineParts(markup, prContext: prContext) {
      switch part {
      case .text(let text): pending.append(text)
      case .media(let media):
        flush()
        result.append(MessageBlock(id: "\(id).\(result.count)", kind: .media(media)))
      case .prImage(let path, let alt):
        flush()
        result.append(MessageBlock(id: "\(id).\(result.count)", kind: .prImage(path: path, alt: alt)))
      }
    }
    flush()
    return result
  }

  private static func inlineParts(_ markup: any Markup,
    prContext: GitHubPRMarkdownContext?) -> [InlinePart] {
    if let image = markup as? Markdown.Image, let source = image.source,
      let url = GitHubPRCommentMedia.allowedURL(source) {
      return [.media(.init(url: url, kind: .image, alt: image.plainText))]
    }
    if let image = markup as? Markdown.Image, let source = image.source,
      let path = prContext?.path(for: source) {
      return [.prImage(path: path, alt: image.plainText)]
    }
    if let html = markup as? InlineHTML, let media = GitHubPRCommentMedia.html(html.rawHTML),
      media.kind == .video {
      return [.media(media)]
    }
    if markup.childCount == 0 || markup is Markdown.Image {
      return [.text(inline(markup, prContext: prContext))]
    }
    var result = markup.children.flatMap { inlineParts($0, prContext: prContext) }
    var intent: InlinePresentationIntent = []
    if markup is Strong { intent = .stronglyEmphasized }
    if markup is Emphasis { intent = .emphasized }
    if markup is Strikethrough { intent = .strikethrough }
    let link = (markup as? Markdown.Link)?.destination.flatMap {
      resolvedLink($0, prContext: prContext)
    }
    if !intent.isEmpty || link != nil {
      result = result.map { part in
        guard case .text(var text) = part else { return part }
        if !intent.isEmpty {
          for run in Array(text.runs) {
            text[run.range].inlinePresentationIntent = (run.inlinePresentationIntent ?? []).union(intent)
          }
        }
        if let link { text.link = link }
        return .text(text)
      }
    }
    return result
  }

  private static func inline(_ markup: any Markup,
    prContext: GitHubPRMarkdownContext?) -> AttributedString {
    switch markup {
    case let text as Markdown.Text: return AttributedString(text.string)
    case let code as InlineCode:
      var result = AttributedString(code.code)
      result.inlinePresentationIntent = .code
      return result
    case is SoftBreak: return AttributedString(" ")
    case is LineBreak: return AttributedString("\n")
    case let html as InlineHTML: return AttributedString(html.rawHTML)
    default: break
    }
    var result = markup.children.reduce(into: AttributedString()) { $0.append(inline($1, prContext: prContext)) }
    var intent: InlinePresentationIntent = []
    if markup is Strong { intent = .stronglyEmphasized }
    if markup is Emphasis { intent = .emphasized }
    if markup is Strikethrough { intent = .strikethrough }
    if !intent.isEmpty {
      for run in Array(result.runs) {
        result[run.range].inlinePresentationIntent = (run.inlinePresentationIntent ?? []).union(
          intent)
      }
    }
    if let link = markup as? Markdown.Link, let target = link.destination {
      result.link = resolvedLink(target, prContext: prContext)
    }
    if let image = markup as? Markdown.Image {
      if result.characters.isEmpty { result = AttributedString("图像") }
      result = AttributedString("↗ ") + result
      result.link = image.source.flatMap { resolvedLink($0, prContext: prContext) }
    }
    return result
  }

  private static func hasMedia(_ block: MessageBlock) -> Bool {
    switch block.kind { case .media, .prImage: return true; default: return false }
  }

  private static func resolvedLink(_ source: String,
    prContext: GitHubPRMarkdownContext?) -> URL? {
    guard let prContext else { return MessageLink.url(source) }
    if let relative = prContext.link(for: source) { return relative }
    guard let external = MessageLink.url(source),
      ["http", "https", "mailto"].contains(external.scheme?.lowercased() ?? "") else { return nil }
    return external
  }
}
