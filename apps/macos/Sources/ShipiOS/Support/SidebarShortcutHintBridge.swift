import AppKit
import Observation
import SwiftUI

struct SidebarShortcutHintContext: Equatable {
  let modifier: NSEvent.ModifierFlags
  let labels: [String: String]
}

@MainActor @Observable final class SidebarShortcutHintController {
  private(set) var labels: [String: String] = [:]
  @ObservationIgnored private var request: SidebarShortcutHintContext?
  @ObservationIgnored private var pending: Task<Void, Never>?
  @ObservationIgnored private var generation = UUID()

  func update(_ context: SidebarShortcutHintContext, held: Bool, eligible: Bool) {
    let next = held && eligible && !context.labels.isEmpty ? context : nil
    guard next != request else { return }
    reset()
    guard let next else { return }
    request = next
    let token = generation
    pending = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
      guard let self, generation == token, request == next else { return }
      labels = next.labels
      pending = nil
    }
  }

  func reset() {
    generation = UUID()
    request = nil
    pending?.cancel()
    pending = nil
    labels = [:]
  }

  deinit { pending?.cancel() }
}

/// Observes modifier changes in this sidebar's window without consuming events.
struct SidebarShortcutHintBridge: NSViewRepresentable {
  let context: SidebarShortcutHintContext
  let controller: SidebarShortcutHintController

  func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }
  func makeNSView(context: Context) -> HintView {
    let view = HintView()
    context.coordinator.install(view)
    view.didMove = { [weak coordinator = context.coordinator] in coordinator?.scheduleRefresh() }
    return view
  }
  func updateNSView(_ view: HintView, context: Context) {
    context.coordinator.context = self.context
    context.coordinator.scheduleRefresh()
  }
  static func dismantleNSView(_ view: HintView, coordinator: Coordinator) {
    view.didMove = nil
    coordinator.stop()
  }

  final class HintView: NSView {
    var didMove: (() -> Void)?
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); didMove?() }
  }

  @MainActor final class Coordinator {
    var context = SidebarShortcutHintContext(modifier: .control, labels: [:])
    private let controller: SidebarShortcutHintController
    private weak var view: NSView?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var refresh: Task<Void, Never>?

    init(controller: SidebarShortcutHintController) { self.controller = controller }

    func install(_ view: NSView) {
      self.view = view
      monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self, weak view] event in
        MainActor.assumeIsolated {
          guard let self else { return event }
          if event.window == nil || event.window === view?.window {
            self.update(flags: event.modifierFlags)
          }
          return event
        }
      }
      for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
        NSWindow.willCloseNotification, NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification,
        NSApplication.didBecomeActiveNotification,
        NSApplication.didResignActiveNotification] {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: nil,
          queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
              guard let self else { return }
              if let window = notification.object as? NSWindow, window !== self.view?.window { return }
              if [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
                NSWindow.willBeginSheetNotification, NSApplication.didResignActiveNotification].contains(name) {
                self.refresh?.cancel()
                self.controller.reset()
              } else {
                self.scheduleRefresh()
              }
            }
          })
      }
    }

    // Updates may originate in SwiftUI's representable pass; publish afterwards.
    func scheduleRefresh() {
      refresh?.cancel()
      refresh = Task { [weak self] in
        guard !Task.isCancelled else { return }
        self?.update(flags: NSEvent.modifierFlags)
      }
    }

    private func update(flags: NSEvent.ModifierFlags) {
      let window = view?.window
      let eligible = window?.isKeyWindow == true && NSApp?.isActive == true
        && window?.attachedSheet == nil && NSApp?.modalWindow == nil
      controller.update(context, held: flags.contains(context.modifier), eligible: eligible)
    }

    func stop() {
      refresh?.cancel()
      refresh = nil
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
      for observer in observers { NotificationCenter.default.removeObserver(observer) }
      observers = []
      view = nil
      controller.reset()
    }

    deinit {
      refresh?.cancel()
      if let monitor { NSEvent.removeMonitor(monitor) }
      for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
  }
}

private struct SidebarShortcutHintLabelsKey: EnvironmentKey {
  static let defaultValue: [String: String] = [:]
}

extension EnvironmentValues {
  var sidebarShortcutHintLabels: [String: String] {
    get { self[SidebarShortcutHintLabelsKey.self] }
    set { self[SidebarShortcutHintLabelsKey.self] = newValue }
  }
}

extension WorkspaceStore {
  var sidebarShortcutHintContext: SidebarShortcutHintContext {
    let modifier: NSEvent.ModifierFlags = shortcuts.primaryNumberShortcutTarget == .sidebar ? .command : .control
    guard libraryLoaded, !showingActivity, destination != .settings, !restoringLibrary, !shuttingDown,
      presentedOverlay == nil, !hasSettingsConfirmation, !mainRenameDialogActive, renameProjectPath == nil,
      !showingModelPicker, !showingBranchPicker, shortcutCaptureCount == 0 else {
      return .init(modifier: modifier, labels: [:])
    }
    let labels = library.visibleSidebarTasks.prefix(9).enumerated().compactMap { index, task -> (String, String)? in
      guard let binding = shortcuts.binding("focus-chat-\(index + 1)") else { return nil }
      return (task.id, binding.display)
    }
    return .init(modifier: modifier, labels: Dictionary(labels, uniquingKeysWith: { first, _ in first }))
  }
}
