import AppKit
import SwiftUI

/// Sonner's Option+T entry point is a focusable region outside normal Tab
/// order. The bridge owns only that native edge; SwiftUI owns each card.
struct NoticeKeyboardBridge: NSViewRepresentable {
  let interaction: NoticeInteractionState
  let focusFirst: () -> Void
  let focusedCard: () -> String?
  let firstCard: () -> String?
  let lastCard: () -> String?
  let focusOrder: () -> [String]
  let focusCard: (String) -> Void
  let focusExitRevision: Int

  func makeCoordinator() -> Coordinator { Coordinator(interaction: interaction) }
  func makeNSView(context: Context) -> Region {
    let region = Region()
    region.setAccessibilityRole(.group)
    region.setAccessibilityLabel("通知 Option+T")
    context.coordinator.attach(region)
    return region
  }
  func updateNSView(_ region: Region, context: Context) {
    context.coordinator.focusFirst = focusFirst
    context.coordinator.focusedCard = focusedCard
    context.coordinator.firstCard = firstCard
    context.coordinator.lastCard = lastCard
    context.coordinator.focusOrder = focusOrder
    context.coordinator.focusCard = focusCard
    if context.coordinator.recordFocusExit(focusExitRevision) { context.coordinator.restoreAfterFocusExit() }
  }
  static func dismantleNSView(_ region: Region, coordinator: Coordinator) { coordinator.stop() }

  final class Region: NSView {
    weak var coordinator: Coordinator?
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func resignFirstResponder() -> Bool {
      let result = super.resignFirstResponder()
      if result { coordinator?.regionDidResign() }
      return result
    }
  }

  @MainActor final class Coordinator {
    private weak var region: Region?
    private weak var previous: NSResponder?
    private weak var previousWindow: NSWindow?
    private weak var previousField: NSTextField?
    private var previousSelection: NSRange?
    private var previousFieldText: String?
    private var monitor: Any?
    private var enteringCard = false
    private var lastFocusExitRevision = 0
    private var active = true
    let interaction: NoticeInteractionState
    var focusFirst: (() -> Void)?
    var focusedCard: (() -> String?)?
    var firstCard: (() -> String?)?
    var lastCard: (() -> String?)?
    var focusOrder: (() -> [String])?
    var focusCard: ((String) -> Void)?
    var hasPreviousFocus: Bool { previous != nil }

    init(interaction: NoticeInteractionState) { self.interaction = interaction }
    func attach(_ region: Region) {
      self.region = region; region.coordinator = self
      interaction.returnFocus = { [weak self] in self?.restoreIfNeeded() }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        let key = NoticeKeySnapshot(event)
        let handled = MainActor.assumeIsolated {
          guard let self, let window = self.region?.window, window.isKeyWindow,
            key.windowNumber == window.windowNumber else { return false }
          return self.handle(key)
        }
        return handled ? nil : event
      }
    }
    /// Isolated entry used by the window-local monitor and hidden-window tests.
    @discardableResult func handle(_ event: NSEvent) -> Bool { handle(NoticeKeySnapshot(event)) }
    private func handle(_ key: NoticeKeySnapshot) -> Bool {
      guard active, let region, let window = region.window,
        key.windowNumber == window.windowNumber else { return false }
      if key.code == 17, key.option {
        guard firstCard?() != nil else { return false }
        guard window.attachedSheet == nil, WindowModalInteraction.allows(region) else { return false }
        if previous == nil, let old = window.firstResponder, old !== region {
          if let editor = old as? NSTextView, editor.isFieldEditor,
            let field = editor.delegate as? NSTextField, field.window === window {
            previous = field; previousField = field
            previousFieldText = field.stringValue; previousSelection = editor.selectedRange()
          } else { previous = old }
          previousWindow = window
        }
        interaction.expandFromKeyboard()
        _ = window.makeFirstResponder(region)
        return true
      }
      if key.code == 53, window.firstResponder === region || focusedCard?() != nil {
        interaction.collapse()
        return false // The source leaves Escape available to the page.
      }
      if key.code == 48, window.firstResponder === region {
        if key.shift { restoreIfNeeded() }
        else {
          enteringCard = true
          focusFirst?()
          DispatchQueue.main.async { [weak self] in self?.enteringCard = false }
        }
        return true
      }
      if key.code == 48, let current = focusedCard?() {
        if let order = focusOrder?(), let index = order.firstIndex(of: current) {
          let next = index + (key.shift ? -1 : 1)
          if order.indices.contains(next) {
            interaction.beginCardTabMovement()
            focusCard?(order[next])
          } else { restoreIfNeeded() }
          return true
        }
        if (key.shift && current == firstCard?()) || (!key.shift && current == lastCard?()) {
          restoreIfNeeded()
          return true
        }
        interaction.beginCardTabMovement()
      }
      return false
    }
    func regionDidResign() {
      guard active, !enteringCard, focusedCard?() == nil else { return }
      DispatchQueue.main.async { [weak self] in
        guard let self, !self.enteringCard, self.focusedCard?() == nil else { return }
        self.restoreIfNeeded()
      }
    }
    func recordFocusExit(_ revision: Int) -> Bool {
      guard revision > lastFocusExitRevision else { return false }
      lastFocusExitRevision = revision; return true
    }
    func restoreAfterFocusExit() {
      // SwiftUI can briefly publish nil between the row and its child button.
      // Let the next focus target settle before treating nil as a real exit.
      let movingWithinCards = interaction.tabMovingWithinCards
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(movingWithinCards ? 100 : 30)) { [weak self] in
        guard let self, self.focusedCard?() == nil else { return }
        self.interaction.finishCardTabMovement()
        self.restoreIfNeeded()
      }
    }
    func restoreIfNeeded() {
      guard active, let region, let window = region.window,
        previousWindow === window, let previous, previous !== region else { clearPrevious(); return }
      let field = previousField, selection = previousSelection, fieldText = previousFieldText
      clearPrevious()
      if let view = previous as? NSView {
        guard view.window === window, WindowModalInteraction.allows(view), view.acceptsFirstResponder else { return }
      }
      guard window.makeFirstResponder(previous) else { return }
      if let field, field.stringValue == fieldText,
        let selection, let editor = field.currentEditor() as? NSTextView,
        NSMaxRange(selection) <= (editor.string as NSString).length {
        editor.setSelectedRange(selection)
      }
    }
    private func clearPrevious() {
      previous = nil; previousWindow = nil
      previousField = nil; previousSelection = nil; previousFieldText = nil
    }
    func stop() {
      active = false
      if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
      interaction.returnFocus = nil
      clearPrevious(); region?.coordinator = nil; region = nil
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
  }
}

enum NoticeTabOrder {
  static func tokens(for notices: [WorkspaceNotice], actionsEnabled: Bool) -> [String] {
    notices.flatMap { notice in
      let base = notice.generation.uuidString
      var order = [base + "-row"]
      let hasAction = actionsEnabled && notice.taskID != nil
      if notice.description == nil && hasAction { order.append(base + "-view") }
      if notice.level != .pending { order.append(base + "-close") }
      if notice.description != nil && hasAction { order.append(base + "-view") }
      return order
    }
  }
}

private struct NoticeKeySnapshot: Sendable {
  let code: UInt16
  let modifiers: UInt
  let windowNumber: Int
  init(_ event: NSEvent) {
    code = event.keyCode; modifiers = event.modifierFlags.rawValue; windowNumber = event.windowNumber
  }
  var option: Bool { modifiers & NSEvent.ModifierFlags.option.rawValue != 0 }
  var shift: Bool { modifiers & NSEvent.ModifierFlags.shift.rawValue != 0 }
}
