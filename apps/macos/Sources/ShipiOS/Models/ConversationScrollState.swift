import Foundation

struct ConversationScrollMetrics: Equatable {
  var offset: Double
  var contentHeight: Double
  var viewportHeight: Double
  var isAtBottom: Bool { contentHeight - viewportHeight - offset <= 40 }
}

/// Content growth must not be mistaken for the reader scrolling upward.
struct ConversationScrollState {
  private(set) var followsLatest = true
  private(set) var isAtBottom = true
  private(set) var hasNewContent = false
  private var interacting = false
  private var seekingLatest = true
  private var navigatingHistory = false
  private var previous: ConversationScrollMetrics?

  mutating func observe(_ metrics: ConversationScrollMetrics) -> Bool {
    guard metrics.viewportHeight > 0 else { return false }
    let layoutChanged =
      previous.map {
        abs($0.contentHeight - metrics.contentHeight) > 0.5
          || abs($0.viewportHeight - metrics.viewportHeight) > 0.5
      } ?? true
    let moved = previous.map { abs($0.offset - metrics.offset) > 0.5 } ?? false
    // Scrollbar, keyboard and accessibility scrolling need not have a live-scroll phase.
    if moved && !layoutChanged && !seekingLatest && !interacting && !navigatingHistory {
      followsLatest = metrics.isAtBottom
    }
    previous = metrics
    isAtBottom = metrics.isAtBottom
    if isAtBottom {
      hasNewContent = false
      if !interacting && !navigatingHistory {
        followsLatest = true
        seekingLatest = false
      }
    }
    return followsLatest && !interacting && !isAtBottom && (layoutChanged || seekingLatest)
  }

  mutating func beginUserScroll() {
    interacting = true
    navigatingHistory = false
    followsLatest = false
    seekingLatest = false
  }

  mutating func endUserScroll(_ metrics: ConversationScrollMetrics) {
    interacting = false
    _ = observe(metrics)
    followsLatest = metrics.isAtBottom
  }

  mutating func pauseFollowing() {
    navigatingHistory = true
    followsLatest = false
    seekingLatest = false
  }

  mutating func endNavigation() {
    navigatingHistory = false
    followsLatest = isAtBottom
  }

  mutating func contentChanged() -> Bool {
    if !followsLatest { hasNewContent = true }
    return followsLatest && !interacting
  }

  mutating func requestLatest() {
    navigatingHistory = false
    followsLatest = true
    seekingLatest = true
    hasNewContent = false
  }
}
