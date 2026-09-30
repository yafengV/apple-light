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
    homeWindow = Self.makeWindow(size: PopoutWindowPlacement.homeSize,
      title: "弹出窗口", resizable: false)
    super.init()
    homeWindow.delegate = self
    homeWindow.contentView = NSHostingView(rootView: PopoutHomeView(store: store,
      onSubmit: { [weak self] prompt, projectless in
        self?.submit(prompt, projectless: projectless) ?? false
      }, onOpenThread: { [weak self] in self?.openThread($0) },
      onHide: { [weak self] in self?.hide() }))
  }

  func toggle() {
    let previous = state.visibleSurface ?? state.lastVisibleSurface
    if let store { state.retainThreads(Set(store.library.tasks.map(\.id))) }
    state.toggle()
    applyState(previous: previous)
  }

  func openHome() {
    let previous = state.visibleSurface ?? state.lastVisibleSurface
    state.openHome()
    applyState(previous: previous)
  }

  func openThread(_ taskID: String) {
    guard store?.library.tasks.contains(where: { $0.id == taskID }) == true else {
      openHome()
      return
    }
    let previous = state.visibleSurface ?? state.lastVisibleSurface
    state.openThread(taskID)
    applyState(previous: previous)
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

  private func applyState(previous: PopoutWindowState.Surface? = nil) {
    switch state.visibleSurface {
    case nil:
      homeWindow.orderOut(nil)
      threadWindow?.orderOut(nil)
    case .home:
      threadWindow?.orderOut(nil)
      positionIfNeeded(homeWindow, home: true)
      if case .thread = previous, let threadWindow,
        positionedWindows.contains(ObjectIdentifier(threadWindow)) {
        alignHome(to: threadWindow)
      }
      present(homeWindow)
    case .thread(let taskID):
      homeWindow.orderOut(nil)
      guard let store else { return }
      if threadWindow == nil {
        let window = Self.makeWindow(size: PopoutWindowPlacement.threadSize,
          title: "弹出会话", resizable: true)
        window.delegate = self
        threadWindow = window
      }
      if renderedThreadID != taskID {
        threadWindow?.contentView = NSHostingView(rootView: PopoutThreadView(store: store,
          taskID: taskID, onHome: { [weak self] in self?.openHome() },
          onOpenThread: { [weak self] in self?.openThread($0) },
          onHide: { [weak self] in self?.hide() }))
        renderedThreadID = taskID
      }
      if let threadWindow {
        positionIfNeeded(threadWindow, home: false)
        if previous == .home,
          positionedWindows.contains(ObjectIdentifier(homeWindow)) {
          alignThread(to: homeWindow)
        }
        present(threadWindow)
      }
    }
  }

  private func present(_ window: PopoutPanel) {
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
  }

  private func positionIfNeeded(_ window: PopoutPanel, home: Bool) {
    guard positionedWindows.insert(ObjectIdentifier(window)).inserted else { return }
    let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
      ?? NSScreen.main
    guard let visible = screen?.visibleFrame else { return }
    let frame = home
      ? PopoutWindowPlacement.initialHome(in: visible, size: window.frame.size,
        threadSize: threadWindow?.frame.size ?? PopoutWindowPlacement.threadSize)
      : PopoutWindowPlacement.initialThread(in: visible, size: window.frame.size)
    window.setFrame(frame, display: false)
  }

  private func alignThread(to home: PopoutPanel) {
    guard let threadWindow, let visible = screen(containing: home)?.visibleFrame else { return }
    threadWindow.setFrame(PopoutWindowPlacement.thread(alignedTo: home.frame,
      in: visible, size: threadWindow.frame.size), display: false)
  }

  private func alignHome(to thread: PopoutPanel) {
    guard let visible = screen(containing: thread)?.visibleFrame else { return }
    homeWindow.setFrame(PopoutWindowPlacement.home(alignedTo: thread.frame,
      in: visible, height: homeWindow.frame.height), display: false)
  }

  private func screen(containing window: NSWindow) -> NSScreen? {
    window.screen ?? NSScreen.screens.first { $0.frame.intersects(window.frame) } ?? NSScreen.main
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
    if resizable { window.minSize = PopoutWindowPlacement.threadMinimumSize }
    return window
  }
}

private final class PopoutPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}
