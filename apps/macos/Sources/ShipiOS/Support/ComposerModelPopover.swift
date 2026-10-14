import AppKit
import SwiftUI

/// Close the native popover before returning the next queued key to its composer.
/// SwiftUI owns presentation; the coordinator owns only this anchor's popover.
struct ComposerModelPopover: NSViewRepresentable {
  let presented: Bool
  let ownerID: String
  let dismiss: (Bool) -> Void
  let content: (@escaping () -> Void) -> AnyView

  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSView {
    let view = Anchor()
    view.owner = context.coordinator
    return view
  }
  func updateNSView(_ view: NSView, context: Context) {
    context.coordinator.update(view, presented: presented, ownerID: ownerID,
      dismiss: dismiss, content: content)
  }
  static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
    coordinator.stop()
  }

  final class Anchor: NSView {
    weak var owner: Coordinator?
  }

  @MainActor final class Coordinator: NSObject, NSPopoverDelegate {
    private(set) var popover: NSPopover?
    private weak var anchor: NSView?
    private var ownerID: String?
    private var dismiss: ((Bool) -> Void)?
    private var restoreOnClose = false
    private var cancelMonitor: Any?

    func update(_ view: NSView, presented: Bool, ownerID: String,
      dismiss: @escaping (Bool) -> Void,
      content: (@escaping () -> Void) -> AnyView) {
      if popover != nil, self.ownerID != ownerID { stop() }
      self.anchor = view; self.ownerID = ownerID; self.dismiss = dismiss
      guard presented else {
        if popover != nil { close(restore: false) }
        return
      }
      guard popover == nil, let window = view.window, window.isKeyWindow,
        window.attachedSheet == nil, NSApp.modalWindow == nil,
        !view.isHiddenOrHasHiddenAncestor else { return }
      let popup = NSPopover()
      popup.behavior = .transient
      popup.animates = false
      popup.delegate = self
      popup.contentViewController = NSHostingController(rootView: content { [weak self] in
        self?.close(restore: true)
      })
      popover = popup
      popup.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
      cancelMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        MainActor.assumeIsolated {
          guard let self, self.handleCancel(event) else { return event }
          return nil
        }
      }
    }

    func handleCancel(_ event: NSEvent) -> Bool {
      guard event.type == .keyDown, event.keyCode == 53,
        event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
        let popover, popover.isShown, let window = anchor?.window,
        NSApp.isActive, window.attachedSheet == nil, NSApp.modalWindow == nil,
        event.window === window || event.window === popover.contentViewController?.view.window
      else { return false }
      // A transient NSPopover otherwise consumes Escape before SwiftUI's
      // onExitCommand and closes without the explicit return-focus callback.
      close(restore: true)
      return true
    }

    func close(restore: Bool) {
      guard let popover else { return }
      restoreOnClose = restore
      popover.close()
    }

    func popoverDidClose(_ notification: Notification) {
      let window = anchor?.window
      let restore = restoreOnClose
      popover?.delegate = nil
      popover = nil; restoreOnClose = false
      if let cancelMonitor { NSEvent.removeMonitor(cancelMonitor) }
      cancelMonitor = nil
      dismiss?(restore)
      // Reenable and focus the retained native editor in this same event.
      // Outside clicks leave their new responder alone.
      if restore, window?.isKeyWindow == true, window?.attachedSheet == nil,
        NSApp.modalWindow == nil {
        window?.contentView?.layoutSubtreeIfNeeded()
      }
    }

    func stop() {
      popover?.delegate = nil
      popover?.close()
      popover = nil; anchor = nil; ownerID = nil; dismiss = nil
      restoreOnClose = false
      if let cancelMonitor { NSEvent.removeMonitor(cancelMonitor) }
      cancelMonitor = nil
    }
  }
}
