import AppKit
import SwiftUI

/// Owns the two short-lived surfaces used by the global Popout Window action.
/// The SwiftUI views own their drafts; AppKit only controls window visibility.
@MainActor
final class PopoutWindowController: NSObject, NSWindowDelegate {
  private weak var store: WorkspaceStore?
  private let homeWindow: PopoutPanel
  private var threadWindow: PopoutPanel?
  private var renderedThreadID: String?
  private var positionedWindows: Set<ObjectIdentifier> = []
  private(set) var state = PopoutWindowState()
  var hasVisibleWindow: Bool { homeWindow.isVisible || threadWindow?.isVisible == true }

  init(store: WorkspaceStore) {
    self.store = store
    homeWindow = Self.makeWindow(size: NSSize(width: 470, height: 290),
      title: "弹出窗口", resizable: false)
    super.init()
    homeWindow.delegate = self
    homeWindow.contentView = NSHostingView(rootView: PopoutHomeView(store: store,
      onSubmit: { [weak self] prompt, projectless in
        self?.submit(prompt, projectless: projectless) ?? false
      }, onHide: { [weak self] in self?.hide() }))
  }

  func toggle() {
    if let store { state.retainThreads(Set(store.library.tasks.map(\.id))) }
    state.toggle()
    applyState()
  }

  func openHome() {
    state.openHome()
    applyState()
  }

  func openThread(_ taskID: String) {
    state.openThread(taskID)
    applyState()
  }

  func hide() {
    state.hide()
    applyState()
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    hide()
    return false
  }

  private func submit(_ prompt: String, projectless: Bool) -> Bool {
    guard let store,
      let task = store.preparePopoutTask(prompt: prompt, projectless: projectless) else { return false }
    openThread(task.id)
    Task { await store.sendTaskWindowDraft(task.id, mode: .standard) }
    return true
  }

  private func applyState() {
    switch state.visibleSurface {
    case nil:
      homeWindow.orderOut(nil)
      threadWindow?.orderOut(nil)
    case .home:
      threadWindow?.orderOut(nil)
      present(homeWindow)
    case .thread(let taskID):
      homeWindow.orderOut(nil)
      guard let store else { return }
      if threadWindow == nil {
        let window = Self.makeWindow(size: NSSize(width: 470, height: 640),
          title: "弹出会话", resizable: true)
        window.delegate = self
        threadWindow = window
      }
      if renderedThreadID != taskID {
        threadWindow?.contentView = NSHostingView(rootView: PopoutThreadView(store: store,
          taskID: taskID, onHome: { [weak self] in self?.openHome() },
          onHide: { [weak self] in self?.hide() }))
        renderedThreadID = taskID
      }
      if let threadWindow { present(threadWindow) }
    }
  }

  private func present(_ window: PopoutPanel) {
    if positionedWindows.insert(ObjectIdentifier(window)).inserted {
      let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
        ?? NSScreen.main
      if let frame = screen?.visibleFrame {
        let width = min(window.frame.width, frame.width)
        let height = min(window.frame.height, frame.height)
        window.setContentSize(NSSize(width: width, height: height))
        let x = frame.midX - width / 2
        let y = frame.maxY - height - 52
        window.setFrameOrigin(NSPoint(x: x, y: max(frame.minY, y)))
      }
    }
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
  }

  private static func makeWindow(size: NSSize, title: String, resizable: Bool) -> PopoutPanel {
    let window = PopoutPanel(contentRect: NSRect(origin: .zero, size: size),
      styleMask: resizable ? [.borderless, .resizable] : [.borderless],
      backing: .buffered, defer: false)
    window.title = title
    window.isReleasedWhenClosed = false
    window.hidesOnDeactivate = false
    window.isMovableByWindowBackground = true
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true
    window.level = .floating
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    if resizable { window.minSize = NSSize(width: 400, height: 400) }
    return window
  }
}

private final class PopoutPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}
