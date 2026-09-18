import SwiftUI

struct TaskSearchResultRow: View {
  let result: TaskSearchResult
  let query: String
  var shortcut: String? = nil
  var body: some View {
    HStack(alignment: .top) {
      Image(systemName: result.task.archived ? "archivebox" : "text.bubble").foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 4) {
        highlighted(result.task.title).lineLimit(1)
        highlighted(result.projectTitle).appFont(.caption).foregroundStyle(.secondary)
        if let snippet = result.snippet, let source = result.source {
          HStack(alignment: .top, spacing: 6) {
            Text(source).appFont(.caption).foregroundStyle(.secondary)
            highlighted(snippet).appFont(.caption).lineLimit(3)
          }
        }
      }
      Spacer()
      if result.task.archived { Text("已归档").appFont(.caption).foregroundStyle(.secondary) }
      if let shortcut, !shortcut.isEmpty { Text(shortcut).appFont(.caption).foregroundStyle(.secondary) }
    }.padding(.vertical, 6).contentShape(Rectangle())
  }
  private func highlighted(_ text: String) -> Text {
    var attributed = AttributedString(text)
    for fragment in DesktopFuzzyQuery(query).match(text)?.ranges ?? [] {
      if let range = Range(fragment, in: text),
        let start = AttributedString.Index(range.lowerBound, within: attributed),
        let end = AttributedString.Index(range.upperBound, within: attributed) {
        attributed[start..<end].backgroundColor = .yellow.opacity(0.35)
      }
    }
    return Text(attributed)
  }
}
