import SwiftUI

struct TaskSearchResultRow: View {
  let result: TaskSearchResult
  let query: String
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
    }.padding(.vertical, 6).contentShape(Rectangle())
  }
  private func highlighted(_ text: String) -> Text {
    var attributed = AttributedString(text)
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if !query.isEmpty {
      var remaining = text.startIndex..<text.endIndex
      while let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: remaining),
        !range.isEmpty {
        if let start = AttributedString.Index(range.lowerBound, within: attributed),
          let end = AttributedString.Index(range.upperBound, within: attributed) {
          attributed[start..<end].backgroundColor = .yellow.opacity(0.35)
        }
        remaining = range.upperBound..<text.endIndex
      }
    }
    return Text(attributed)
  }
}
