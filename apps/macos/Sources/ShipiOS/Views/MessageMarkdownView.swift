import AppKit
import SwiftUI

struct MessageMarkdownView: View {
  @Environment(\.appAppearance) private var appearance
  let source: String
  var runID = ""
  var partPrefix = "response"
  var linkActions: MessageLinkActions?
  let openLink: (URL) -> Void
  @State private var blocks: [MessageBlock] = []

  var body: some View {
    MessageBlocksView(blocks: blocks)
      .environment(\.conversationRunID, runID)
      .environment(\.conversationResponsePart, partPrefix)
      .environment(\.messageLinkActions, linkActions)
      .appFont(size: 14).lineSpacing(5).textSelection(.enabled)
      .tint(appearance.accentColor)
      .environment(
        \.openURL,
        OpenURLAction { url in
          openLink(url)
          return .handled
        }
      )
      .task(id: source) {
        let input = source
        let result = await Task.detached(priority: .userInitiated) { MessageDocument.parse(input) }
          .value
        guard !Task.isCancelled else { return }
        blocks = result
      }
  }
}

private struct MessageBlocksView: View {
  let blocks: [MessageBlock]
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      ForEach(blocks) { block in MessageBlockView(block: block) }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct MessageBlockView: View {
  @Environment(\.conversationRunID) private var runID
  @Environment(\.conversationResponsePart) private var partPrefix
  let block: MessageBlock
  @ViewBuilder var body: some View {
    switch block.kind {
    case .paragraph:
      ConversationSearchText(block.text, id: .init(run: runID, part: partPrefix + "." + block.id)).frame(
        maxWidth: .infinity, alignment: .leading
      )
      .fixedSize(horizontal: false, vertical: true)
    case .heading(let level):
      ConversationSearchText(block.text, id: .init(run: runID, part: partPrefix + "." + block.id),
        nativeFontSize: level == 1 ? 23 : level == 2 ? 19 : 16, nativeWeight: .semibold)
        .appFont(size: level == 1 ? 23 : level == 2 ? 19 : 16, weight: .semibold)
        .accessibilityAddTraits(.isHeader).padding(.top, 6)
    case .code(let language):
      MessageCodeBlock(
        source: block.source, language: language,
        searchID: .init(run: runID, part: partPrefix + "." + block.id))
    case .quote:
      HStack(alignment: .top, spacing: 12) {
        Rectangle().fill(.secondary.opacity(0.35)).frame(width: 3)
        AnyView(MessageBlocksView(blocks: block.children)).foregroundStyle(.secondary)
          .environment(\.messageTextIsSecondary, true)
      }.fixedSize(horizontal: false, vertical: true)
    case .list:
      AnyView(MessageBlocksView(blocks: block.children))
    case .item(let marker, let checked):
      HStack(alignment: .top, spacing: 8) {
        if let checked {
          Image(systemName: checked ? "checkmark.square" : "square")
            .accessibilityLabel(checked ? "已完成" : "未完成").padding(.top, 3)
        } else {
          Text(marker).monospacedDigit().frame(minWidth: 16, alignment: .trailing)
        }
        AnyView(MessageBlocksView(blocks: block.children))
      }
    case .table:
      MessageTableView(block: block)
    case .rule:
      Divider().padding(.vertical, 4)
    }
  }
}

private struct MessageCodeBlock: View {
  let source: String
  let language: String
  let searchID: ConversationTextID
  @State private var copied = false
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(language.isEmpty ? "代码" : language).appFont(.caption).foregroundStyle(.secondary)
        Spacer()
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(source, forType: .string)
          copied = true
        } label: {
          Label(copied ? "已复制" : "复制代码", systemImage: copied ? "checkmark" : "doc.on.doc")
        }.buttonStyle(.plain).appFont(.caption).help("复制完整代码块")
          .accessibilityLabel(copied ? "已复制代码" : "复制 \(language) 代码块")
      }.padding(.horizontal, 12).padding(.vertical, 9)
      Divider()
      SearchHorizontalScroll {
        ConversationSearchText(
          source.hasSuffix("\n") ? String(source.dropLast()) : source, id: searchID
        )
        .appFont(size: 12, design: .monospaced).lineSpacing(3)
        .fixedSize(horizontal: true, vertical: false).padding(12)
      }
    }.background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.09)))
      .onChange(of: source) { _, _ in copied = false }
      .task(id: copied) {
        guard copied else { return }
        try? await Task.sleep(for: .seconds(2))
        if !Task.isCancelled { copied = false }
      }
  }
}

private struct MessageTableView: View {
  @Environment(\.conversationRunID) private var runID
  @Environment(\.conversationResponsePart) private var partPrefix
  let block: MessageBlock
  var body: some View {
    SearchHorizontalScroll {
      Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
        ForEach(block.rows.indices, id: \.self) { row in
          GridRow {
            ForEach(block.rows[row].indices, id: \.self) { column in
              ConversationSearchText(
                block.rows[row][column],
                id: .init(run: runID, part: "\(partPrefix).\(block.id).cell.\(row).\(column)"),
                nativeWeight: row == 0 ? .semibold : .regular
              )
              .fontWeight(row == 0 ? .semibold : .regular)
              .frame(minWidth: 100, maxWidth: 280, alignment: alignment(column))
              .padding(.horizontal, 12).padding(.vertical, 9)
              .background(.primary.opacity(row == 0 ? 0.06 : row.isMultiple(of: 2) ? 0.025 : 0))
              .overlay(alignment: .bottom) { Divider() }
            }
          }
        }
      }.fixedSize(horizontal: true, vertical: false)
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.primary.opacity(0.09)))
    }
  }
  private func alignment(_ column: Int) -> Alignment {
    guard block.alignments.indices.contains(column) else { return .leading }
    return block.alignments[column] == 1
      ? .trailing : block.alignments[column] == 0 ? .center : .leading
  }
}
