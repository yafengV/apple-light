import SwiftUI

enum ConversationRailPreviewDocument {
  enum Part: Equatable, Sendable {
    case text(AttributedString)
    case table([[AttributedString]])
  }

  static func parse(_ source: String) -> [Part] {
    var result: [Part] = []
    var text = AttributedString()
    func flush() {
      guard !text.characters.isEmpty else { return }
      result.append(.text(text))
      text = AttributedString()
    }
    for block in MessageDocument.parse(source) {
      if case .table = block.kind {
        flush()
        result.append(.table(block.rows))
      } else {
        let next = flatten(block)
        guard !next.characters.isEmpty else { continue }
        if !text.characters.isEmpty { text.append(AttributedString("\n")) }
        text.append(next)
      }
    }
    flush()
    return result
  }

  private static func flatten(_ block: MessageBlock) -> AttributedString {
    switch block.kind {
    case .paragraph: return block.text
    case .heading:
      var heading = block.text
      for run in Array(heading.runs) {
        heading[run.range].inlinePresentationIntent =
          (run.inlinePresentationIntent ?? []).union(.stronglyEmphasized)
      }
      return heading
    case .code: return AttributedString(block.source.trimmingCharacters(in: .newlines))
    case .rule: return AttributedString("—")
    case .quote, .list:
      return joined(block.children.map(flatten), separator: "\n")
    case .item(let marker, _):
      return AttributedString(marker + " ") + joined(block.children.map(flatten), separator: " ")
    case .table: return AttributedString()
    case .media(let media): return AttributedString(media.alt)
    }
  }

  private static func joined(_ parts: [AttributedString], separator: String) -> AttributedString {
    var result = AttributedString()
    for part in parts where !part.characters.isEmpty {
      if !result.characters.isEmpty { result.append(AttributedString(separator)) }
      result.append(part)
    }
    return result
  }
}

struct ConversationRailMarkdownPreview: View {
  let source: String
  @State private var parts: [ConversationRailPreviewDocument.Part] = []

  var body: some View {
    Group {
      if parts.isEmpty {
        Text((try? AttributedString(markdown: source,
          options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
          ?? AttributedString(source)).lineLimit(3)
      } else {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(parts.indices, id: \.self) { index in
            switch parts[index] {
            case .text(let value):
              Text(value).lineLimit(parts.contains(where: { if case .table = $0 { true } else { false } })
                ? nil : 3)
            case .table(let rows):
              table(rows)
            }
          }
        }
      }
    }
    .appFont(.caption).foregroundStyle(.secondary)
    .frame(maxWidth: .infinity, alignment: .leading)
    .environment(\.openURL, OpenURLAction { _ in .discarded })
    .task(id: source) {
      parts = []
      let input = source
      let parsed = await Task.detached(priority: .userInitiated) {
        ConversationRailPreviewDocument.parse(input)
      }.value
      if !Task.isCancelled { parts = parsed }
    }
  }

  private func table(_ rows: [[AttributedString]]) -> some View {
    let columns = max(1, rows.map(\.count).max() ?? 1)
    let width = 296 / CGFloat(columns)
    return Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
      ForEach(rows.indices, id: \.self) { row in
        GridRow {
          ForEach(0..<columns, id: \.self) { column in
            Text(rows[row].indices.contains(column) ? rows[row][column] : AttributedString())
              .fontWeight(row == 0 ? .semibold : .regular)
              .lineLimit(1).truncationMode(.middle)
              .frame(width: width - 8, alignment: .leading)
              .padding(4)
              .background(.primary.opacity(row == 0 ? 0.06 : 0))
              .overlay(alignment: .bottom) { Divider() }
          }
        }
      }
    }
    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.primary.opacity(0.1)))
  }
}
