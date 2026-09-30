import Foundation

/// Builds a focused, line-numbered file diff for a proposed selection replacement.
enum FileSelectionReviewDiff {
  private enum Kind { case context, addition, deletion }
  private struct Row {
    let kind: Kind
    let text: String
  }

  static func make(old: String, new: String) -> ReviewDiff {
    let before = old.components(separatedBy: "\n")
    let after = new.components(separatedBy: "\n")
    var prefix = 0
    while prefix < min(before.count, after.count), before[prefix] == after[prefix] { prefix += 1 }
    var suffix = 0
    while suffix < min(before.count, after.count) - prefix,
      before[before.count - suffix - 1] == after[after.count - suffix - 1] { suffix += 1 }
    guard prefix + suffix < max(before.count, after.count) else { return ReviewDiff("") }

    let first = max(0, prefix - 3)
    let beforeEnd = before.count - suffix
    let afterEnd = after.count - suffix
    let oldMiddle = Array(before[prefix..<beforeEnd])
    let newMiddle = Array(after[prefix..<afterEnd])
    var rows = before[first..<prefix].map { Row(kind: .context, text: $0) }
    if oldMiddle.count + newMiddle.count > 800 {
      // A completely rewritten 32 KiB selection can contain thousands of tiny
      // lines. Keep the review responsive instead of running a quadratic diff.
      rows += oldMiddle.map { Row(kind: .deletion, text: $0) }
      rows += newMiddle.map { Row(kind: .addition, text: $0) }
    } else {
      let changes = newMiddle.difference(from: oldMiddle)
      var removed = Set<Int>(), inserted = Set<Int>()
      for change in changes {
        switch change {
        case .remove(let offset, _, _): removed.insert(offset)
        case .insert(let offset, _, _): inserted.insert(offset)
        }
      }
      var oldIndex = 0, newIndex = 0
      while oldIndex < oldMiddle.count || newIndex < newMiddle.count {
        if removed.contains(oldIndex) {
          rows.append(Row(kind: .deletion, text: oldMiddle[oldIndex])); oldIndex += 1
        } else if inserted.contains(newIndex) {
          rows.append(Row(kind: .addition, text: newMiddle[newIndex])); newIndex += 1
        } else if oldIndex < oldMiddle.count, newIndex < newMiddle.count {
          rows.append(Row(kind: .context, text: oldMiddle[oldIndex])); oldIndex += 1; newIndex += 1
        } else if oldIndex < oldMiddle.count {
          rows.append(Row(kind: .deletion, text: oldMiddle[oldIndex])); oldIndex += 1
        } else {
          rows.append(Row(kind: .addition, text: newMiddle[newIndex])); newIndex += 1
        }
      }
    }
    let following = min(3, suffix)
    rows += before[beforeEnd..<(beforeEnd + following)].map { Row(kind: .context, text: $0) }
    let oldCount = rows.filter { $0.kind != .addition }.count
    let newCount = rows.filter { $0.kind != .deletion }.count
    let oldStart = oldCount == 0 ? first : first + 1
    let newStart = newCount == 0 ? first : first + 1
    let header = "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
    let lines = rows.map { row in
      let prefix: String
      switch row.kind {
      case .context: prefix = " "
      case .addition: prefix = "+"
      case .deletion: prefix = "-"
      }
      return prefix + row.text.replacingOccurrences(of: "\r", with: "␍")
    }
    return ReviewDiff(([header] + lines).joined(separator: "\n"))
  }
}
