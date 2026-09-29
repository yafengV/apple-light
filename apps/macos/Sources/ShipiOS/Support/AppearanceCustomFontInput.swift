import AppKit
import SwiftUI

/// A menu input owns only a draft. Enter or the explicit menu item applies it;
/// cancellation, focus changes, and teardown never save it implicitly.
struct AppearanceCustomFontInput: NSViewRepresentable {
  let menu: AppearanceFontMenuState
  let label: String
  let apply: () -> Void
  @Environment(\.appAppearance) private var appearance
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> Control {
    let field = Control(); field.owner = context.coordinator; field.delegate = context.coordinator
    field.cell = Cell(textCell: ""); field.isBezeled = false; field.isBordered = false; field.drawsBackground = false
    field.focusRingType = .none; field.isEditable = true; field.isSelectable = true
    field.cell?.usesSingleLineMode = true; field.cell?.isScrollable = true
    field.stringValue = menu.draft; return field
  }
  func updateNSView(_ field: Control, context: Context) {
    context.coordinator.parent = self
    field.font = appearance.nativeFont(size: 13); field.textColor = NSColor(appearance.foregroundColor)
    field.setAccessibilityLabel(label); field.setAccessibilityIdentifier("appearance-custom-font-input")
    if field.currentEditor() == nil { field.stringValue = menu.draft }
    field.needsDisplay = true
  }
  static func dismantleNSView(_ field: Control, coordinator: Coordinator) {
    coordinator.active = false; field.owner = nil; field.delegate = nil
  }
  final class Cell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
      let inset = rect.insetBy(dx: 8, dy: 0)
      return .init(x: inset.minX, y: inset.midY - 8, width: inset.width, height: 16)
    }
  }
  final class Control: NSTextField {
    weak var owner: Coordinator?
    private var focused = false
    override var alignmentRectInsets: NSEdgeInsets { .init(top: 0, left: 0, bottom: 0, right: 0) }
    override var intrinsicContentSize: NSSize { .init(width: 224, height: 28) }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard !focused, let window else { return }; focused = true
      DispatchQueue.main.async { [weak self, weak window] in
        guard let self, let window, self.window === window, self.owner?.canAct(self) == true else { return }
        window.makeFirstResponder(self)
        if let editor = self.currentEditor() as? NSTextView {
          editor.isAutomaticSpellingCorrectionEnabled = false; editor.isContinuousSpellCheckingEnabled = false
          editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
          editor.isAutomaticTextReplacementEnabled = false
          editor.setSelectedRange(.init(location: (self.stringValue as NSString).length, length: 0))
        }
      }
    }
  }
  @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: AppearanceCustomFontInput
    var active = true
    init(_ parent: AppearanceCustomFontInput) { self.parent = parent }
    func canAct(_ field: NSTextField) -> Bool {
      active && parent.menu.presented && parent.menu.custom && field.window != nil && field.isEnabled && !field.isHiddenOrHasHiddenAncestor
    }
    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField, canAct(field) else { return }
      parent.menu.draft = field.stringValue
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      guard let field = control as? NSTextField, canAct(field), !textView.hasMarkedText() else { return false }
      if selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
        parent.menu.draft = textView.string; parent.apply(); return true
      }
      // The reference input stops keyboard propagation, including Escape.
      if selector == #selector(NSResponder.cancelOperation(_:)) { return true }
      return false
    }
  }
}
