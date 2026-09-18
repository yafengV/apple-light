import AppKit
import SwiftUI

/// Retained settings pages must remove disabled editors from the native key loop.
struct SettingsTextEditor: NSViewRepresentable {
  @Binding var text: String
  let label: String
  var placeholder: String = ""
  var focusRequest: UUID?
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.appAppearance) private var appearance

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    let editor = TextView()
    editor.isRichText = false
    editor.allowsUndo = true
    editor.drawsBackground = false
    editor.isHorizontallyResizable = false
    editor.isVerticallyResizable = true
    editor.textContainer?.widthTracksTextView = true
    editor.textContainerInset = NSSize(width: 0, height: 5)
    editor.delegate = context.coordinator
    scroll.documentView = editor
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let editor = scroll.documentView as? TextView else { return }
    context.coordinator.parent = self
    editor.setEnabled(isEnabled)
    editor.placeholder = placeholder
    editor.setAccessibilityLabel(label)
    editor.font = appearance.nativeFont(size: 13)
    editor.textColor = NSColor(appearance.foregroundColor)
    if editor.string != text, !editor.hasMarkedText() {
      let selection = editor.selectedRange()
      editor.string = text
      let length = (text as NSString).length
      let location = min(selection.location, length)
      editor.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
      editor.undoManager?.removeAllActions()
    }
    context.coordinator.updateFocus(editor, enabled: isEnabled, request: focusRequest)
  }

  static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
    coordinator.active = false
    (scroll.documentView as? TextView)?.setEnabled(false)
    (scroll.documentView as? TextView)?.delegate = nil
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: SettingsTextEditor
    var active = true
    private var lastFocusRequest: UUID?
    private var focusGeneration = UUID()
    private var enabled = true
    init(_ parent: SettingsTextEditor) { self.parent = parent }
    func updateFocus(_ editor: TextView, enabled: Bool, request: UUID?) {
      if self.enabled != enabled { focusGeneration = UUID() }
      self.enabled = enabled
      guard request != lastFocusRequest else { return }
      lastFocusRequest = request
      focusGeneration = UUID()
      let generation = focusGeneration
      guard enabled, request != nil else { return }
      DispatchQueue.main.async { [weak self, weak editor] in
        guard let self, self.active, self.enabled, self.focusGeneration == generation,
          let editor, editor.isEditable, !editor.isHiddenOrHasHiddenAncestor,
          let window = editor.window else { return }
        window.makeFirstResponder(editor)
      }
    }
    func textDidChange(_ notification: Notification) {
      guard active, parent.isEnabled, let editor = notification.object as? TextView,
        editor.isEditable, !editor.hasMarkedText() else { return }
      parent.text = editor.string
    }
  }

  final class TextView: NSTextView {
    var placeholder = "" { didSet { if placeholder != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
      super.draw(dirtyRect)
      guard string.isEmpty, !placeholder.isEmpty, !hasMarkedText() else { return }
      (placeholder as NSString).draw(at: NSPoint(
        x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
        y: textContainerInset.height), withAttributes: [
          .font: font ?? NSFont.systemFont(ofSize: 13),
          .foregroundColor: NSColor.placeholderTextColor
        ])
    }

    override var acceptsFirstResponder: Bool { isEditable && super.acceptsFirstResponder }
    override var canBecomeKeyView: Bool { isEditable && super.canBecomeKeyView }

    func setEnabled(_ enabled: Bool) {
      isEditable = enabled
      isSelectable = enabled
      if !enabled, window?.firstResponder === self { window?.makeFirstResponder(nil) }
    }

    override func keyDown(with event: NSEvent) {
      guard isEditable else { return }
      if event.keyCode == 48, !hasMarkedText(),
        event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
        if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
        else { window?.selectNextKeyView(self) }
        return
      }
      super.keyDown(with: event)
    }
  }
}
