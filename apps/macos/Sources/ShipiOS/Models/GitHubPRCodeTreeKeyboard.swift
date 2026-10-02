import Foundation

enum GitHubPRCodeTreeKeyboard {
  enum Direction { case up, down, left, right, first, last }

  static func move(_ direction: Direction, from id: String,
    rows: [GitHubPRCodeTreeNode.Row], collapsed: inout Set<String>) -> String? {
    guard let index = rows.firstIndex(where: { $0.id == id }) else { return rows.first?.id }
    let row = rows[index]
    switch direction {
    case .up: return rows[max(0, index - 1)].id
    case .down: return rows[min(rows.count - 1, index + 1)].id
    case .first: return rows.first?.id
    case .last: return rows.last?.id
    case .right:
      if row.node.file == nil, collapsed.contains(id) {
        collapsed.remove(id)
        return id
      }
      return rows[min(rows.count - 1, index + 1)].id
    case .left:
      if row.node.file == nil, !collapsed.contains(id) {
        collapsed.insert(id)
        return id
      }
      return row.parentID ?? id
    }
  }
}
