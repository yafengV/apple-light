import AppKit
import SwiftUI

/// PR comments use the ordinary (non-wide) Markdown table surface.
struct PRCommentMarkdownTableView: View {
  let block: MessageBlock
  let source: String
  @Environment(\.appAppearance) private var appearance
  @State private var measuredHeight: CGFloat?
  @State private var hovered = false
  @State private var scrollTarget = PRCommentTableScrollTarget()
  private var metrics: PRCommentTableMetrics { .init(appearance: appearance) }
  var body: some View {
    GeometryReader { geometry in
      SearchHorizontalScroll {
        PRCommentTableLayout(block: block, metrics: metrics, availableWidth: geometry.size.width) {
          ForEach(block.rows.indices, id: \.self) { row in
            ForEach(block.rows[row].indices, id: \.self) { column in
              cell(row, column)
            }
          }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background { PRCommentTableScrollAnchor(target: scrollTarget) }
        .background { GeometryReader { inner in Color.clear.preference(key: PRCommentTableHeightKey.self, value: inner.size.height) } }
      }
      .overlay(alignment: .topTrailing) {
        PRCommentTableCopyToolbar(block: block, hovered: hovered, scroll: { scrollTarget.scroll($0, page: $1) }).frame(width: 40, height: 40)
      }
    }
    .frame(height: measuredHeight ?? metrics.plan(block, width: nil).height)
    .onHover { hovered = $0 }
    .onPreferenceChange(PRCommentTableHeightKey.self) { height in
      if height.isFinite, height > 0, measuredHeight != height { measuredHeight = height }
    }
  }
  @ViewBuilder private func cell(_ row: Int, _ column: Int) -> some View {
    let padding = metrics.padding(row: row, column: column, rows: block.rows.count, columns: block.rows[row].count)
    Group {
      if block.mediaRows.indices.contains(row), block.mediaRows[row].indices.contains(column),
        block.mediaRows[row][column].contains(where: { if case .media = $0.kind { true } else { false } }) {
        PRCommentMarkdownBlocksView(blocks: block.mediaRows[row][column], source: source, layout: nil)
      } else {
        PRCommentMarkdownText(text: block.rows[row][column], font: metrics.font,
          lineHeight: row == 0 ? 13 : 21.125, weight: row == 0 ? .semibold : .regular,
          source: source, layout: nil, alignment: metrics.alignment(block, column: column))
      }
    }
    .padding(.top, padding.top).padding(.bottom, padding.bottom + (row == 0 || row < block.rows.count - 1 ? 1 : 0))
    .padding(.trailing, padding.right)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .overlay(alignment: .bottom) {
      if row == 0 || row < block.rows.count - 1 {
        Rectangle().fill(appearance.resolvedColors[row == 0 ? "borderHeavy" : "borderLight"].color).frame(height: 1)
      }
    }
  }
}

struct PRCommentTableMetrics {
  let appearance: AppearancePreferences
  var font: NSFont {
    let base = appearance.nativeFont(size: 13, content: true).withSize(max(CGFloat(appearance.codeSize), 13 * 0.875))
    return NSFont(descriptor: base.fontDescriptor.addingAttributes([.featureSettings: [[
      NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
      NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector
    ]]]), size: base.pointSize) ?? base
  }
  struct Padding { let top: CGFloat; let right: CGFloat; let bottom: CGFloat }
  struct Plan { let columns: [CGFloat]; let rows: [CGFloat]; var height: CGFloat { rows.reduce(0, +) }; var width: CGFloat { columns.reduce(0, +) } }
  func padding(row: Int, column: Int, rows: Int, columns: Int) -> Padding {
    .init(top: row == 0 ? 6.5 : 8.125,
      right: column == columns - 1 ? (row == 0 ? 32.5 : 0) : 19.5,
      bottom: row == 0 ? 6.5 : row == rows - 1 ? 19.5 : 8.125)
  }
  func alignment(_ block: MessageBlock, column: Int) -> NSTextAlignment {
    guard block.alignments.indices.contains(column) else { return .left }
    return block.alignments[column] == 0 ? .center : block.alignments[column] == 1 ? .right : .left
  }
  func attributed(_ text: AttributedString, header: Bool) -> NSAttributedString {
    LegacyMessageLinkText.attributedText(text, appearance: appearance, size: font.pointSize,
      weight: header ? .semibold : .regular, lineSpacing: 0, fontOverride: font,
      lineHeight: header ? 13 : 21.125, inlineCodeScale: 0.92)
  }
  func measure(_ text: NSAttributedString, width: CGFloat) -> CGSize {
    let storage = NSTextStorage(attributedString: text), manager = NSLayoutManager()
    let container = NSTextContainer(containerSize: .init(width: max(1, width), height: .greatestFiniteMagnitude))
    container.lineFragmentPadding = 0; storage.addLayoutManager(manager); manager.addTextContainer(container)
    manager.ensureLayout(for: container); return manager.usedRect(for: container).size
  }
  func plan(_ block: MessageBlock, width: CGFloat?) -> Plan {
    let count = block.rows.map(\.count).max() ?? 0
    guard count > 0 else { return .init(columns: [], rows: []) }
    var preferred = Array(repeating: CGFloat(0), count: count), minimum = preferred
    for (row, cells) in block.rows.enumerated() {
      for (column, text) in cells.enumerated() {
        let pad = padding(row: row, column: column, rows: block.rows.count, columns: cells.count)
        let content = attributed(text, header: row == 0)
        preferred[column] = max(preferred[column], min(480, measure(content, width: 10_000).width + pad.right))
        let plain = String(text.characters)
        let words = plain.split(whereSeparator: { $0.isWhitespace })
        var narrow = words.map { measure(attributed(AttributedString(String($0)), header: row == 0), width: 10_000).width }.max() ?? 0
        if row > 0, !plain.isEmpty, plain.utf8.allSatisfy({ (48...57).contains($0) }) {
          narrow = max(narrow, measure(attributed(AttributedString("000"), header: false), width: 10_000).width + 19.5 - pad.right)
        }
        minimum[column] = max(minimum[column], min(480, narrow + pad.right))
      }
    }
    let low = minimum.reduce(0, +), high = preferred.reduce(0, +)
    let target = max(low, width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? high)
    let columns: [CGFloat]
    if target >= high {
      columns = preferred.map { high > 0 ? $0 * target / high : target / CGFloat(count) }
    } else {
      columns = preferred.indices.map { minimum[$0] + (preferred[$0] - minimum[$0]) * (target - low) / max(1, high - low) }
    }
    let heights = block.rows.enumerated().map { row, cells in
      cells.enumerated().map { column, text -> CGFloat in
        let pad = padding(row: row, column: column, rows: block.rows.count, columns: cells.count)
        return measure(attributed(text, header: row == 0), width: columns[column] - pad.right).height + pad.top + pad.bottom + (row == 0 || row < block.rows.count - 1 ? 1 : 0)
      }.max() ?? 0
    }
    return .init(columns: columns, rows: heights)
  }
}

struct PRCommentTableLayout: Layout {
  let block: MessageBlock
  let metrics: PRCommentTableMetrics
  let availableWidth: CGFloat
  private func plan(_ subviews: Subviews) -> PRCommentTableMetrics.Plan {
    let initial = metrics.plan(block, width: availableWidth)
    var index = 0
    let heights = block.rows.map { cells in
      var height: CGFloat = 0
      for column in cells.indices {
        if subviews.indices.contains(index) {
          height = max(height, subviews[index].sizeThatFits(.init(width: initial.columns[column], height: nil)).height)
        }
        index += 1
      }
      return height
    }
    return .init(columns: initial.columns, rows: heights)
  }
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let plan = plan(subviews)
    return .init(width: plan.width, height: plan.height)
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let plan = plan(subviews)
    var index = 0, y = bounds.minY
    for (row, cells) in block.rows.enumerated() {
      var x = bounds.minX
      for column in cells.indices {
        guard subviews.indices.contains(index) else { return }
        subviews[index].place(at: .init(x: x, y: y), proposal: .init(width: plan.columns[column], height: plan.rows[row]))
        index += 1; x += plan.columns[column]
      }
      y += plan.rows[row]
    }
  }
}

private struct PRCommentTableHeightKey: PreferenceKey {
  static var defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
