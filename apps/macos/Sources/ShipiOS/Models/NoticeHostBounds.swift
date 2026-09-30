import CoreGraphics
import Observation
import SwiftUI

/// Reference to the app shell's measured toast area. The desktop toaster is
/// portaled to the main content surface, not centered across the sidebar.
struct NoticeHostBounds: Equatable {
  static let coordinateSpace = "shipios-notice-host"
  var root: CGRect?
  var detail: CGRect?
  var workspace: CGRect?

  func rect(for destination: AppDestination) -> CGRect? {
    let preferred = destination == .workspace ? workspace ?? detail : detail ?? workspace
    guard let preferred, preferred.width > 0, preferred.height > 0 else { return root }
    guard let root else { return preferred }
    let clipped = preferred.intersection(root)
    return clipped.isNull || clipped.width <= 0 || clipped.height <= 0 ? root : clipped
  }
}

@MainActor @Observable final class NoticeHostBoundsTracker {
  enum Region { case root, detail, workspace }
  private(set) var bounds = NoticeHostBounds()
  func record(_ region: Region, frame: CGRect) {
    guard frame.width > 0, frame.height > 0 else { return }
    switch region {
    case .root: if bounds.root != frame { bounds.root = frame }
    case .detail: if bounds.detail != frame { bounds.detail = frame }
    case .workspace: if bounds.workspace != frame { bounds.workspace = frame }
    }
  }
}

private struct NoticeHostBoundsTrackerKey: EnvironmentKey {
  static let defaultValue: NoticeHostBoundsTracker? = nil
}

extension EnvironmentValues {
  var noticeHostBoundsTracker: NoticeHostBoundsTracker? {
    get { self[NoticeHostBoundsTrackerKey.self] }
    set { self[NoticeHostBoundsTrackerKey.self] = newValue }
  }
}

struct NoticeHostFrameReporter: View {
  let region: NoticeHostBoundsTracker.Region
  @Environment(\.noticeHostBoundsTracker) private var tracker
  init(_ region: NoticeHostBoundsTracker.Region) { self.region = region }
  var body: some View {
    GeometryReader { proxy in
      let frame = proxy.frame(in: .named(NoticeHostBounds.coordinateSpace))
      Color.clear
        .onAppear { tracker?.record(region, frame: frame) }
        .onChange(of: frame) { _, value in tracker?.record(region, frame: value) }
    }
  }
}
