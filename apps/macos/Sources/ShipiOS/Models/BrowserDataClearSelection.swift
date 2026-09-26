import Foundation
import WebKit

enum BrowserDataTimeRange: String, CaseIterable, Identifiable {
  case lastHour, lastDay, lastWeek, lastFourWeeks, allTime

  var id: Self { self }
  var title: String {
    switch self {
    case .lastHour: "过去一小时"
    case .lastDay: "过去 24 小时"
    case .lastWeek: "过去 7 天"
    case .lastFourWeeks: "过去 4 周"
    case .allTime: "所有时间"
    }
  }
  func cutoff(relativeTo now: Date) -> Date {
    switch self {
    case .lastHour: now.addingTimeInterval(-3_600)
    case .lastDay: now.addingTimeInterval(-86_400)
    case .lastWeek: now.addingTimeInterval(-7 * 86_400)
    case .lastFourWeeks: now.addingTimeInterval(-28 * 86_400)
    case .allTime: .distantPast
    }
  }
}

struct BrowserDataClearSelection {
  var range: BrowserDataTimeRange = .allTime
  var history = true
  var cookies = true
  var cache = true
  var otherWebsiteData = true

  var hasSelection: Bool { history || cookies || cache || otherWebsiteData }

  var websiteDataTypes: Set<String> {
    let cookieTypes: Set<String> = [WKWebsiteDataTypeCookies]
    let cacheTypes: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache]
    var selected = Set<String>()
    if cookies { selected.formUnion(cookieTypes) }
    if cache { selected.formUnion(cacheTypes) }
    if otherWebsiteData {
      selected.formUnion(WKWebsiteDataStore.allWebsiteDataTypes().subtracting(cookieTypes).subtracting(cacheTypes))
    }
    return selected
  }
}
