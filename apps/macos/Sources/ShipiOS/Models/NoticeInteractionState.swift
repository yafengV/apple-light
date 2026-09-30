import Foundation
import Observation

@Observable final class NoticeInteractionState {
  let notices: WorkspaceNotices
  private let uptime: () -> TimeInterval
  private(set) var hovered: Set<UUID> = []
  private(set) var keyboardExpanded = false
  private(set) var interacting = false
  private(set) var documentHidden = false
  @ObservationIgnored @MainActor var returnFocus: (() -> Void)?
  @ObservationIgnored private(set) var tabMovingWithinCards = false
  var expanded: Bool { keyboardExpanded }
  var paused: Bool { expanded || interacting || documentHidden }

  init(notices: WorkspaceNotices, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
    self.notices = notices; self.uptime = uptime
  }

  func tick() { notices.advance(to: uptime()) }
  func pointerMoved(over generation: UUID) {
    guard hovered.insert(generation).inserted || !keyboardExpanded else { return }
    change { keyboardExpanded = true }
  }
  func pointerLeft(_ generation: UUID) {
    guard hovered.remove(generation) != nil else { return }
    if hovered.isEmpty, !interacting { change { keyboardExpanded = false } }
    else { synchronize() }
  }
  func expandFromKeyboard() { change { keyboardExpanded = true } }
  func collapse() { change { keyboardExpanded = false } }
  func setInteracting(_ value: Bool) {
    guard interacting != value else { return }
    change { interacting = value; if !value { keyboardExpanded = false } }
  }
  func setDocumentHidden(_ value: Bool) { guard documentHidden != value else { return }; change { documentHidden = value } }
  func remove(_ generations: Set<UUID>) {
    let retained = hovered.intersection(generations)
    guard retained != hovered || (generations.isEmpty && keyboardExpanded) else { return }
    change {
      hovered = retained
      if generations.isEmpty || (retained.isEmpty && !interacting) { keyboardExpanded = false }
    }
  }
  func stop() {
    hovered = []; keyboardExpanded = false; interacting = false; documentHidden = false
    notices.setPaused(false, at: uptime())
  }
  @MainActor func returnToPreviousFocus() { returnFocus?() }
  func beginCardTabMovement() { tabMovingWithinCards = true }
  func finishCardTabMovement() { tabMovingWithinCards = false }
  private func change(_ update: () -> Void) {
    // Charge the preceding interval under the old reasons, then change state.
    let now = uptime()
    notices.advance(to: now)
    update()
    notices.setPaused(paused, at: now)
  }
  private func synchronize() { notices.setPaused(paused, at: uptime()) }
}
