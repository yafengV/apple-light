import Foundation
import Observation

struct NoticeVisualExit: Identifiable {
  let notice: WorkspaceNotice
  let index: Int
  let offset: CGFloat
  let scale: CGFloat
  let frameHeight: CGFloat
  let naturalHeight: CGFloat
  let leavesUpward: Bool
  let startedAt: TimeInterval
  var outward = false
  var id: UUID { notice.generation }
  var exitOffset: CGFloat { leavesUpward ? -naturalHeight : naturalHeight * 0.4 }
}

/// Keeps a removed card on screen for Sonner's 200 ms removal window while
/// surviving cards immediately move to their new stack positions.
@Observable final class NoticeVisualTimeline {
  private(set) var active: [WorkspaceNotice] = []
  private(set) var entering: Set<UUID> = []
  private(set) var exiting: [NoticeVisualExit] = []
  private(set) var heights: [UUID: CGFloat] = [:]
  private(set) var revision = 0
  @ObservationIgnored private var swiped: Set<UUID> = []

  init(initial: [WorkspaceNotice] = []) { active = initial }

  func recordHeights(_ values: [UUID: CGFloat]) {
    for (key, height) in values where height > 0 && heights[key] != height { heights[key] = height }
  }

  func markSwiped(_ generation: UUID) { swiped.insert(generation) }

  @discardableResult func reconcile(_ live: [WorkspaceNotice], expanded: Bool,
    at uptime: TimeInterval) -> Bool {
    let before = active.map(\.generation), after = live.map(\.generation)
    guard before != after else { return false }
    let liveIDs = Set(after), oldIDs = Set(before)
    let previous = NoticeStackLayout(heights: active.map { heights[$0.generation] ?? 42 }, expanded: expanded)
    for (index, notice) in active.enumerated() where !liveIDs.contains(notice.generation) {
      guard !swiped.contains(notice.generation) else { continue }
      exiting.append(NoticeVisualExit(notice: notice, index: index,
        offset: previous.offset(index), scale: previous.scale(index),
        frameHeight: previous.containerHeight(index),
        naturalHeight: heights[notice.generation] ?? 42,
        leavesUpward: index == 0 || expanded, startedAt: uptime))
    }
    active = live
    entering.formIntersection(liveIDs)
    entering.formUnion(liveIDs.subtracting(oldIDs))
    swiped.formIntersection(liveIDs)
    revision += 1
    return true
  }

  func settleEntry(revision expected: Int) {
    guard revision == expected else { return }
    entering.removeAll()
  }

  func beginExit(revision expected: Int) {
    guard revision == expected else { return }
    for index in exiting.indices { exiting[index].outward = true }
  }

  func removeFinished(at uptime: TimeInterval) {
    exiting.removeAll { uptime - $0.startedAt >= 0.2 }
    let retained = Set(active.map(\.generation)).union(exiting.map(\.id))
    let pruned = heights.filter { retained.contains($0.key) }
    if pruned != heights { heights = pruned }
  }
}
