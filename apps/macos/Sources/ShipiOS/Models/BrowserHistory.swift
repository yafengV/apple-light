import Foundation

struct BrowserHistoryEntry: Codable, Equatable, Identifiable {
  var id = UUID()
  var url: String
  var title: String
  var visitedAt = Date()
}
