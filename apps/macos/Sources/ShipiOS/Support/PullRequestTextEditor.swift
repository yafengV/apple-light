import AppKit
import SwiftUI

/// The native text system owns selection, undo and IME; SwiftUI owns the committed draft.
struct PullRequestTextEditor: NSViewRepresentable {
  @Binding var text: String
  let field: GitHubPREditField
  let focus: UUID?
  let submit: () -> Void
  let cancel: () -> Void
  var focusProbe: PullRequestEditorFocusProbe? = nil
  @Environment(\.isEnabled) private var enabled
  @Environment(\.appAppearance) private var appearance
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
    let editor = TextView()
    editor.isRichText = false; editor.allowsUndo = true; editor.drawsBackground = false
    editor.isHorizontallyResizable = false; editor.isVerticallyResizable = true
    editor.textContainer?.widthTracksTextView = true
    editor.textContainerInset = NSSize(width: 2, height: 5)
    editor.delegate = context.coordinator; scroll.documentView = editor
    return scroll
  }
  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let editor = scroll.documentView as? TextView else { return }
    context.coordinator.parent = self
    editor.field = field; editor.submit = submit; editor.cancel = cancel
    editor.isEditable = enabled; editor.isSelectable = enabled
    let font = appearance.nativeFont(size: field == .title ? 16 : 13)
    editor.font = field == .title ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font
    editor.textColor = NSColor(appearance.foregroundColor)
    editor.setAccessibilityLabel(field == .title ? "PR 标题" : "PR 描述")
    focusProbe?.record(editor)
    if !editor.hasMarkedText(), editor.string != text {
      let location = min(editor.selectedRange().location, (text as NSString).length)
      editor.string = text; editor.setSelectedRange(NSRange(location: location, length: 0))
      editor.undoManager?.removeAllActions()
    }
    context.coordinator.updateFocus(editor, token: focus, enabled: enabled)
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
    guard field == .title, let editor = nsView.documentView as? TextView,
      let container = editor.textContainer, let layout = editor.layoutManager else { return nil }
    let width = max(60, proposal.width ?? 300)
    container.containerSize = NSSize(width: width - 4, height: .greatestFiniteMagnitude)
    layout.ensureLayout(for: container)
    return CGSize(width: width, height: min(96, max(30, layout.usedRect(for: container).height + 10)))
  }
  static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
    coordinator.active = false
    coordinator.clearUndoObservers()
    (scroll.documentView as? TextView)?.delegate = nil
    (scroll.documentView as? TextView)?.isEditable = false
  }
  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: PullRequestTextEditor
    var active = true
    private var focused: UUID?
    private var scheduled: UUID?
    private weak var observedUndo: UndoManager?
    private var undoObservers: [NSObjectProtocol] = []
    init(_ parent: PullRequestTextEditor) { self.parent = parent }
    deinit { undoObservers.forEach { NotificationCenter.default.removeObserver($0) } }
    func clearUndoObservers() {
      undoObservers.forEach { NotificationCenter.default.removeObserver($0) }
      undoObservers = []; observedUndo = nil
    }
    private func observeUndo(_ editor: NSTextView) {
      guard let manager = editor.undoManager, observedUndo !== manager else { return }
      clearUndoObservers(); observedUndo = manager
      undoObservers = [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange].map { name in
        NotificationCenter.default.addObserver(forName: name, object: manager, queue: .main) { [weak self, weak editor] _ in
          MainActor.assumeIsolated {
            guard let self, self.active, let editor else { return }
            self.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
          }
        }
      }
    }
    func updateFocus(_ editor: TextView, token: UUID?, enabled: Bool) {
      guard enabled, let token else { scheduled = nil; return }
      guard token != focused, token != scheduled else { return }
      scheduled = token
      DispatchQueue.main.async { [weak self, weak editor] in
        guard let self, self.active, self.scheduled == token, self.parent.enabled,
          let editor, editor.isEditable, let window = editor.window,
          !editor.isHiddenOrHasHiddenAncestor else { return }
        window.makeFirstResponder(editor)
        self.parent.focusProbe?.record(editor)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        self.focused = token; self.scheduled = nil
      }
    }
    func textDidChange(_ notification: Notification) {
      guard active, parent.enabled, let editor = notification.object as? TextView,
        editor.isEditable, !editor.hasMarkedText() else { return }
      observeUndo(editor)
      let raw = editor.string
      let value = parent.field == .title ? GitHubPREditText.title(raw) : raw
      if value != raw {
        let location = min(editor.selectedRange().location, (raw as NSString).length)
        let prefix = (raw as NSString).substring(to: location)
        editor.string = value
        editor.setSelectedRange(NSRange(location: (GitHubPREditText.title(prefix) as NSString).length, length: 0))
      }
      parent.text = value
    }
    func textDidBeginEditing(_ notification: Notification) {
      if let editor = notification.object as? TextView { parent.focusProbe?.record(editor); observeUndo(editor) }
    }
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
      replacementString: String?) -> Bool {
      guard active, parent.enabled, parent.field == .title, !textView.hasMarkedText(),
        let replacementString else { return true }
      let normalized = GitHubPREditText.title(replacementString)
      guard normalized != replacementString else { return true }
      // Normalize before AppKit registers undo ranges, rather than shortening an inserted paste later.
      textView.insertText(normalized, replacementRange: affectedCharRange)
      return false
    }
  }
  final class TextView: NSTextView {
    var field = GitHubPREditField.title
    var submit: () -> Void = {}
    var cancel: () -> Void = {}
    override var acceptsFirstResponder: Bool { isEditable && super.acceptsFirstResponder }
    override var canBecomeKeyView: Bool { isEditable && super.canBecomeKeyView }
    override func keyDown(with event: NSEvent) {
      guard isEditable else { return }
      if !hasMarkedText() {
        if event.keyCode == 36 || event.keyCode == 76 {
          if field == .title || !event.modifierFlags.intersection([.command, .control]).isEmpty {
            submit(); return
          }
        }
        if event.keyCode == 53, field == .title { cancel(); return }
        if event.keyCode == 48, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
          if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
          else { window?.selectNextKeyView(self) }
          return
        }
      }
      super.keyDown(with: event)
    }
  }
}

/// A view-local weak probe lets an exiting editor avoid stealing another control's focus.
@MainActor final class PullRequestEditorFocusProbe {
  private weak var editor: NSTextView?
  private weak var window: NSWindow?
  func record(_ editor: NSTextView) {
    self.editor = editor
    if let window = editor.window { self.window = window }
  }
  var mayReturnFocus: Bool {
    guard let window else { return false }
    return window.firstResponder == nil || window.firstResponder === window || window.firstResponder === editor
  }
}
