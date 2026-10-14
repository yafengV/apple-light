import SwiftUI

struct ReviewFileTreeView: View {
  let paths: [String]
  let selectedPath: String?
  let counts: [String: (added: Int, removed: Int)]
  let select: (String) -> Void
  @State private var query = ""
  @State private var collapsed = Set<String>()
  @FocusState private var focusedID: String?
  @Environment(\.appAppearance) private var appearance

  private var rows: [ReviewFileTreeNode.Row] {
    ReviewFileTreeNode.rows(ReviewFileTreeNode.tree(paths: paths, query: query),
      collapsed: collapsed)
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 5) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("筛选文件…", text: $query).textFieldStyle(.plain)
          .accessibilityLabel("筛选审查文件")
          .onSubmit {
            if let path = rows.first(where: { $0.node.path != nil })?.node.path { select(path) }
          }
        if !query.isEmpty {
          Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
            .buttonStyle(.plain).accessibilityLabel("清除审查文件筛选")
        }
      }.padding(8)
      Divider()
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 1) {
            if rows.isEmpty {
              Text(query.isEmpty ? "没有变更文件" : "没有匹配的文件")
                .foregroundStyle(.secondary).padding(10)
            }
            ForEach(rows) { row in
              Button { activate(row.node) } label: {
                HStack(spacing: 5) {
                  Image(systemName: row.node.path == nil
                    ? (collapsed.contains(row.id) ? "chevron.right" : "chevron.down") : "doc.text")
                    .foregroundStyle(.secondary).frame(width: 12)
                  Text(row.node.name).lineLimit(1).truncationMode(.middle)
                  Spacer(minLength: 0)
                  if let path = row.node.path, let count = counts[path] {
                    Text("+\(count.added)").foregroundStyle(appearance.diffAddedColor)
                    Text("-\(count.removed)").foregroundStyle(appearance.diffRemovedColor)
                  }
                }.padding(.leading, CGFloat(row.depth) * 12 + 7).padding(.trailing, 7)
                  .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                  .contentShape(Rectangle())
                  .background(row.node.path != nil && row.node.path == selectedPath
                    ? appearance.accentColor.opacity(0.14) : .clear,
                    in: RoundedRectangle(cornerRadius: 5))
              }.buttonStyle(.plain).help(row.node.path ?? row.node.id.dropFirst(7).description)
                .accessibilityLabel(row.node.path ?? row.node.name)
                .accessibilityValue(row.node.path == nil
                  ? (collapsed.contains(row.id) ? "已收起" : "已展开")
                  : (row.node.path == selectedPath ? "已选中" : "未选中"))
                .accessibilityIdentifier("review-tree-" + row.id)
                .focused($focusedID, equals: row.id).id(row.id)
                .onKeyPress(.upArrow) { move(-1, from: row.id) }
                .onKeyPress(.downArrow) { move(1, from: row.id) }
                .onKeyPress(.leftArrow) {
                  if row.node.path == nil, !collapsed.contains(row.id) { collapsed.insert(row.id) }
                  else if let parent = row.parentID { focusedID = parent }
                  return .handled
                }
                .onKeyPress(.rightArrow) {
                  if row.node.path == nil {
                    if collapsed.contains(row.id) { collapsed.remove(row.id) }
                    else { focusedID = row.node.children.first?.id }
                  }
                  return .handled
                }
                .onKeyPress(.return) { activate(row.node); return .handled }
            }
          }.padding(4)
        }
        .onChange(of: focusedID) { _, id in if let id { proxy.scrollTo(id) } }
      }
    }.appFont(size: 12)
      .accessibilityIdentifier("review-file-tree")
      .onChange(of: query) { _, _ in collapsed = [] }
  }

  private func activate(_ node: ReviewFileTreeNode) {
    if let path = node.path { select(path) }
    else if !collapsed.insert(node.id).inserted { collapsed.remove(node.id) }
  }

  private func move(_ offset: Int, from id: String) -> KeyPress.Result {
    guard let index = rows.firstIndex(where: { $0.id == id }) else { return .ignored }
    focusedID = rows[min(rows.count - 1, max(0, index + offset))].id
    return .handled
  }
}
