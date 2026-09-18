import SwiftUI
import WebKit
import SwiftTerm

@MainActor @Observable final class TaskRenameUndoRouting {
  var nativeUndo = false
  var nativeRedo = false
  var panelOwnsUndo = false
  private weak var window: NSWindow?

  func refresh(_ window: NSWindow?) {
    self.window = window
    let responder = window?.firstResponder
    nativeUndo = responder?.undoManager?.canUndo == true
    nativeRedo = responder?.undoManager?.canRedo == true
    panelOwnsUndo = false
    var view = responder as? NSView
    while let item = view {
      if item is WKWebView || item is TerminalView { panelOwnsUndo = true; break }
      view = item.superview
    }
  }

  func context(history: TaskRenameHistory, store: WorkspaceStore, blocked: Bool, revealInMain: Bool) -> TaskRenameUndoCommands {
    func allowed(_ redo: Bool) -> Bool {
      guard !blocked, history.canPerform(redo: redo, store: store) else { return false }
      guard revealInMain else { return true }
      let entry = (redo ? history.redoEntries : history.undoEntries).last
      return store.library.tasks.first { $0.id == entry?.taskID }.map(store.canSelectTask) == true
    }
    return TaskRenameUndoCommands(
      canUndo: nativeUndo || panelOwnsUndo || allowed(false),
      canRedo: nativeRedo || panelOwnsUndo || allowed(true),
      undoTitle: nativeUndo || panelOwnsUndo || blocked ? "撤销" : "撤销任务重命名",
      redoTitle: nativeRedo || panelOwnsUndo || blocked ? "重做" : "重做任务重命名",
      perform: { [weak self] redo in
        guard let self, let window = self.window, window.isKeyWindow else { return }
        self.refresh(window)
        if self.panelOwnsUndo {
          NSApp.sendAction(NSSelectorFromString(redo ? "redo:" : "undo:"), to: nil, from: nil)
        } else if let manager = window.firstResponder?.undoManager, redo ? manager.canRedo : manager.canUndo {
          if redo { manager.redo() } else { manager.undo() }
        } else if allowed(redo) {
          let id = history.perform(redo: redo, store: store)
          if revealInMain, let id, let task = store.library.tasks.first(where: { $0.id == id }) {
            store.selectTask(task)
          }
        }
        self.refresh(window)
      })
  }
}

struct TaskRenameUndoCommands {
  let canUndo: Bool
  let canRedo: Bool
  let undoTitle: String
  let redoTitle: String
  let perform: (Bool) -> Void
}
private struct TaskRenameUndoKey: FocusedValueKey { typealias Value = TaskRenameUndoCommands }
extension FocusedValues {
  var taskRenameUndo: TaskRenameUndoCommands? {
    get { self[TaskRenameUndoKey.self] }
    set { self[TaskRenameUndoKey.self] = newValue }
  }
}

struct TaskRenameUndoBridge: NSViewRepresentable {
  let routing: TaskRenameUndoRouting
  let context: TaskRenameUndoCommands
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    context.coordinator.install(view, routing: routing)
    return view
  }
  func updateNSView(_ view: NSView, context: Context) { context.coordinator.commands = self.context }
  static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.stop() }
  final class Coordinator {
    var commands: TaskRenameUndoCommands?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    func install(_ view: NSView, routing: TaskRenameUndoRouting) {
      for name in [NSText.didChangeNotification, NSWindow.didBecomeKeyNotification,
        NSNotification.Name.NSUndoManagerDidUndoChange, NSNotification.Name.NSUndoManagerDidRedoChange,
        NSNotification.Name.NSUndoManagerDidCloseUndoGroup] {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak view, weak routing] _ in
          DispatchQueue.main.async { [weak view, weak routing] in
            guard let window = view?.window, window.isKeyWindow else { return }
            routing?.refresh(window)
          }
        })
      }
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self, weak view, weak routing] event in
        MainActor.assumeIsolated {
          guard let window = view?.window, window.isKeyWindow, event.window === window else { return event }
          DispatchQueue.main.async { [weak view, weak routing] in
            guard let window = view?.window, window.isKeyWindow else { return }
            routing?.refresh(window)
          }
          guard event.type == .keyDown, window.attachedSheet == nil, NSApp.modalWindow == nil,
            (window.firstResponder as? NSTextView)?.hasMarkedText() != true,
            event.charactersIgnoringModifiers?.lowercased() == "z" else { return event }
          let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
          guard flags == .command || flags == [.command, .shift] else { return event }
          // Native text, browser and terminal handlers retain first refusal.
          routing?.refresh(window)
          let redo = flags.contains(.shift)
          guard routing?.panelOwnsUndo != true,
            (redo ? routing?.nativeRedo : routing?.nativeUndo) != true,
            let commands = self?.commands, redo ? commands.canRedo : commands.canUndo else { return event }
          commands.perform(redo)
          return nil
        }
      }
    }
    func stop() {
      if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
      for observer in observers { NotificationCenter.default.removeObserver(observer) }
      observers.removeAll(); commands = nil
    }
    deinit { stop() }
  }
}
