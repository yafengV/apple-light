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
  }
  let id: String
  let kind: Kind
  var text = AttributedString()
  var source = ""
  var children: [MessageBlock] = []
  var rows: [[AttributedString]] = []
  /// -1 = leading, 0 = center, 1 = trailing.
  var alignments: [Int] = []
}

enum MessageDocument {
  static func parse(_ source: String) -> [MessageBlock] {
    blocks(Document(parsing: source), prefix: "")
  }

  private static func blocks(_ markup: any Markup, prefix: String) -> [MessageBlock] {
    markup.children.enumerated().map { index, child in
      block(child, id: prefix + "\(index)")
    }
  }

  private static func block(_ markup: any Markup, id: String) -> MessageBlock {
    switch markup {
    case let heading as Heading:
      return MessageBlock(id: id, kind: .heading(heading.level), text: inline(heading))
    case let code as CodeBlock:
      return MessageBlock(id: id, kind: .code(code.language ?? ""), source: code.code)
    case is BlockQuote:
      return MessageBlock(id: id, kind: .quote, children: blocks(markup, prefix: id + "."))
    case is UnorderedList, is OrderedList:
      let start = (markup as? OrderedList)?.startIndex
      let items = markup.children.enumerated().map { offset, child in
        let item = child as? ListItem
        return MessageBlock(
          id: id + ".\(offset)",
          kind: .item(
            start.map { "\($0 + UInt(offset))." } ?? "•", item?.checkbox.map { $0 == .checked }),
          children: blocks(child, prefix: id + ".\(offset)."))
      }
      return MessageBlock(id: id, kind: .list, children: items)
    case let table as Markdown.Table:
      let rows =
        [Array(table.head.cells.map { inline($0) })]
        + table.body.rows.map { Array($0.cells.map { inline($0) }) }
      return MessageBlock(
        id: id, kind: .table, rows: rows,
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
      return MessageBlock(id: id, kind: .paragraph, text: inline(markup))
    }
  }

  private static func inline(_ markup: any Markup) -> AttributedString {
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
    var result = markup.children.reduce(into: AttributedString()) { $0.append(inline($1)) }
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
      result.link = MessageLink.url(target)
    }
    if let image = markup as? Markdown.Image {
      if result.characters.isEmpty { result = AttributedString("图像") }
      result = AttributedString("↗ ") + result
      result.link = image.source.flatMap(MessageLink.url)
    }
    return result
  }
}
