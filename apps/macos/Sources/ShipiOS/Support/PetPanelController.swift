import AppKit
import SwiftUI

@MainActor
final class PetPanelController {
  private let panel: FloatingPetPanel
  private weak var store: WorkspaceStore?
  private var moveObserver: NSObjectProtocol?
  private var applyingFrame = false

  init(store: WorkspaceStore) {
    self.store = store
    panel = FloatingPetPanel(
      contentRect: NSRect(x: 0, y: 0, width: 286, height: 220),
      styleMask: [.borderless], backing: .buffered, defer: false)
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.isMovableByWindowBackground = true
    panel.contentView = NSHostingView(rootView: PetOverlayView(store: store))
    moveObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didMoveNotification, object: panel, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        guard let self, !self.applyingFrame else { return }
        self.store?.savePetPosition(self.panel.frame.origin)
      }
    }
    apply(store.petPreferences)
  }

  func apply(_ preferences: PetPreferences) {
    let base = preferences.selected == .mini ? NSSize(width: 330, height: 72) : NSSize(width: 286, height: 220)
    let size = NSSize(width: base.width * preferences.scale, height: base.height * preferences.scale)
    applyingFrame = true
    let oldOrigin = panel.frame.origin
    panel.setContentSize(size)
    if let x = preferences.originX, let y = preferences.originY {
      panel.setFrameOrigin(NSPoint(x: x, y: y))
    } else if oldOrigin == .zero, let screen = NSScreen.main {
      panel.setFrameOrigin(NSPoint(
        x: screen.visibleFrame.maxX - size.width - 28,
        y: screen.visibleFrame.minY + 36))
    }
    applyingFrame = false
    if preferences.visible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
  }

  deinit {
    if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
  }
}

private final class FloatingPetPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}
