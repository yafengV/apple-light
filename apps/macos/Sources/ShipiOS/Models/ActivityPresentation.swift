import Foundation

struct ActivityPreferences: Codable, Equatable {
  var showPriority = true
  var showPinned = false
  var showScheduled = false

  enum CodingKeys: CodingKey { case showPriority, showPinned, showScheduled }
  init() {}
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    showPriority = try values.decodeIfPresent(Bool.self, forKey: .showPriority) ?? true
    showPinned = try values.decodeIfPresent(Bool.self, forKey: .showPinned) ?? false
    showScheduled = try values.decodeIfPresent(Bool.self, forKey: .showScheduled) ?? false
  }
}

/// Priority membership survives reading or finishing a task until explicitly cleared.
/// This is window state, not another unread flag in the task database.
struct ActivitySession: Equatable {
  var id = UUID()
  var activatedAt: Date
  var priorityIDs: [String]
  var recentDates: [String: Date]
}

struct ActivitySection: Identifiable {
  enum ID: Hashable { case priority, pinned, day(Date) }
  let id: ID
  let title: String
  let items: [ActivityTaskEntry]
}
