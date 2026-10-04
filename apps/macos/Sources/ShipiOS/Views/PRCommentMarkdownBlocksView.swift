import AppKit
import SwiftUI

struct PRCommentMarkdownBlocksView: View {
  let blocks: [MessageBlock]
  let source: String
  let layout: PRCommentMarkdownLayout?
  var container: PRCommentMarkdownTypography.Container = .root
  var trailing: CGFloat = 0
  var listDepth = 0
  @Environment(\.appAppearance) private var appearance
  private var metrics: PRCommentMarkdownTypography { .init(font: appearance.nativeFont(size: 13, content: true).withSize(13)) }
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
        content(block).padding(.top, metrics.gap(blocks, before: index, in: container))
          .padding(.bottom, index == blocks.count - 1 ? metrics.margins(blocks, at: index, in: container).bottom : 0)
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  @ViewBuilder private func content(_ block: MessageBlock) -> some View {
    switch block.kind {
    case .paragraph:
      text(block.text)
    case .heading(let level):
      text(block.text, font: metrics.font.withSize(metrics.headingSize(level)),
        lineHeight: metrics.headingLineHeight(level), weight: .semibold)
        .accessibilityAddTraits(.isHeader)
    case .quote:
      PRCommentMarkdownBlocksView(blocks: block.children, source: source, layout: layout,
        container: .quote, trailing: trailing + metrics.space * 2, listDepth: listDepth)
        .padding(.leading, metrics.space * 6)
        .overlay(alignment: .leading) {
          RoundedRectangle(cornerRadius: metrics.space / 2).fill(appearance.resolvedColors["borderHeavy"].color)
            .frame(width: metrics.space)
        }
        .padding(.vertical, metrics.space * 2)
    case .list:
      PRCommentMarkdownBlocksView(blocks: block.children, source: source, layout: layout, container: .list, trailing: trailing, listDepth: listDepth + 1)
    case .table:
      PRCommentMarkdownTableView(block: block, source: source)
    case .item(let marker, let checked):
      HStack(alignment: .top, spacing: metrics.space * 1.5) {
        Group {
          if let checked { Image(systemName: checked ? "checkmark.square" : "square").accessibilityLabel(checked ? "已完成" : "未完成") }
          else { Text(PRCommentMarkdownTypography.listMarker(marker, depth: listDepth)).monospacedDigit() }
        }.font(Font(metrics.font).weight(.semibold)).frame(width: metrics.lineHeight, height: metrics.lineHeight, alignment: .trailing)
        PRCommentMarkdownBlocksView(blocks: block.children, source: source, layout: layout, container: .item, trailing: trailing, listDepth: listDepth)
      }
    default:
      PRCommentMarkdownFallbackBlock(block: block)
    }
  }
  private func text(_ value: AttributedString, font: NSFont? = nil, lineHeight: CGFloat? = nil,
    weight: NSFont.Weight = .regular) -> some View {
    PRCommentMarkdownText(text: value, font: font ?? metrics.font, lineHeight: lineHeight ?? metrics.lineHeight,
      weight: weight, source: source, layout: layout, trailing: trailing)
      .fixedSize(horizontal: false, vertical: true)
  }
}
