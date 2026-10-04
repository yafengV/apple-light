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
  var accessibilityName: String? = nil
  var selectionChanged: ((String, NSRange) -> Void)? = nil
  var lostFocus: (() -> Void)? = nil
  var handleKey: ((NSEvent) -> Bool)? = nil
  var replacement: PullRequestTextReplacement? = nil
  var growsWithContent = false
  var placeholder: String? = nil
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
    context.coordinator.updatingView = true
    defer { context.coordinator.updatingView = false }
    editor.field = field; editor.submit = submit; editor.cancel = cancel
    editor.handleKey = handleKey
    editor.growing = growsWithContent; editor.placeholder = placeholder
    editor.placeholderColor = appearance.resolvedColors["textForegroundTertiary"].nativeColor
    editor.textContainerInset = growsWithContent ? .zero : .init(width: 2, height: 5)
    editor.textContainer?.lineFragmentPadding = growsWithContent ? 0 : 5
    editor.needsDisplay = true
    editor.isEditable = enabled; editor.isSelectable = enabled
    let font = appearance.nativeFont(size: field == .title || growsWithContent ? 16 : 13)
    editor.font = field == .title ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font
    if growsWithContent, !editor.hasMarkedText(), editor.defaultParagraphStyle?.minimumLineHeight != 28 {
      let paragraph = NSMutableParagraphStyle(); paragraph.minimumLineHeight = 28; paragraph.maximumLineHeight = 28
      editor.defaultParagraphStyle = paragraph; editor.typingAttributes[.paragraphStyle] = paragraph
    }
    editor.textColor = NSColor(appearance.foregroundColor)
    editor.setAccessibilityLabel(accessibilityName ?? (field == .title ? "PR 标题" : "PR 描述"))
    focusProbe?.record(editor)
    if !editor.hasMarkedText(), editor.string != text {
      let location = min(editor.selectedRange().location, (text as NSString).length)
      editor.string = text; editor.setSelectedRange(NSRange(location: location, length: 0))
      editor.undoManager?.removeAllActions()
    }
    context.coordinator.updateFocus(editor, token: focus, enabled: enabled)
    context.coordinator.updateReplacement(editor, replacement: replacement)
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
    guard field == .title || growsWithContent, let editor = nsView.documentView as? TextView,
      let container = editor.textContainer, let layout = editor.layoutManager else { return nil }
    let width = max(60, proposal.width ?? 300)
    container.containerSize = NSSize(width: width - (growsWithContent ? 0 : 4), height: .greatestFiniteMagnitude)
    layout.ensureLayout(for: container)
    let usedHeight = max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY) + 10
    return CGSize(width: width, height: Self.fittedHeight(usedHeight, growing: growsWithContent))
  }
  static func fittedHeight(_ measured: CGFloat, growing: Bool) -> CGFloat {
    growing ? min(192, max(38, measured)) : min(96, max(30, measured))
  }
  static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
    coordinator.active = false
    coordinator.clearUndoObservers()
    (scroll.documentView as? TextView)?.delegate = nil
    (scroll.documentView as? TextView)?.isEditable = false
  }
  @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: PullRequestTextEditor
    var active = true
    var updatingView = false
    private var focused: UUID?
    private var scheduled: UUID?
    private var scheduledReplacement: UUID?
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
        guard let self, self.active, self.scheduled == token else { return }
        self.scheduled = nil
        guard self.parent.enabled,
          let editor, editor.isEditable, let window = editor.window,
          !editor.isHiddenOrHasHiddenAncestor, WindowModalInteraction.allows(editor) else { return }
        guard window.makeFirstResponder(editor) else { return }
        self.parent.focusProbe?.record(editor)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        self.focused = token
      }
    }
    func textDidChange(_ notification: Notification) {
      guard active, parent.enabled, let editor = notification.object as? TextView,
        editor.isEditable, WindowModalInteraction.allows(editor), !editor.hasMarkedText() else { return }
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
      selectionChanged(editor)
    }
    func textDidBeginEditing(_ notification: Notification) {
      if let editor = notification.object as? TextView { parent.focusProbe?.record(editor); observeUndo(editor); selectionChanged(editor) }
    }
    func textDidEndEditing(_ notification: Notification) { if active { parent.lostFocus?() } }
    func textViewDidChangeSelection(_ notification: Notification) {
      if let editor = notification.object as? TextView { selectionChanged(editor) }
    }
    private func selectionChanged(_ editor: TextView) {
      guard active, !updatingView, parent.enabled, editor.isEditable, WindowModalInteraction.allows(editor), !editor.hasMarkedText() else { return }
      parent.selectionChanged?(editor.string, editor.selectedRange())
    }
    func updateReplacement(_ editor: TextView, replacement: PullRequestTextReplacement?) {
      guard let replacement, scheduledReplacement != replacement.id else { return }
      scheduledReplacement = replacement.id
      DispatchQueue.main.async { [weak self, weak editor] in
        guard let self, self.active, self.parent.enabled, let editor,
          self.parent.replacement?.id == replacement.id else { return }
        guard WindowModalInteraction.allows(editor) else { return }
        if let window = editor.window, window.firstResponder !== editor { return }
        _ = editor.apply(replacement)
      }
    }
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
      replacementString: String?) -> Bool {
      guard active, parent.enabled, textView.isEditable, WindowModalInteraction.allows(textView) else { return false }
      guard parent.field == .title, !textView.hasMarkedText(),
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
    var handleKey: ((NSEvent) -> Bool)?
    var growing = false
    var placeholder: String?
    var placeholderColor = NSColor.tertiaryLabelColor
    override var textContainerOrigin: NSPoint { growing ? .init(x: 0, y: 10) : super.textContainerOrigin }
    override func draw(_ dirtyRect: NSRect) {
      super.draw(dirtyRect)
      if string.isEmpty, let placeholder {
        var attributes: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: 16), .foregroundColor: placeholderColor]
        if let defaultParagraphStyle { attributes[.paragraphStyle] = defaultParagraphStyle }
        let origin = textContainerOrigin
        NSAttributedString(string: placeholder, attributes: attributes).draw(in:
          NSRect(x: origin.x, y: origin.y, width: max(0, bounds.width - origin.x), height: max(0, bounds.height - origin.y)))
      }
    }
    override var acceptsFirstResponder: Bool { isEditable && WindowModalInteraction.allows(self) && super.acceptsFirstResponder }
    override var canBecomeKeyView: Bool { isEditable && WindowModalInteraction.allows(self) && super.canBecomeKeyView }
    override func keyDown(with event: NSEvent) {
      guard isEditable, WindowModalInteraction.allows(self) else { return }
      if !hasMarkedText() {
        if handleKey?(event) == true { return }
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
    @discardableResult func apply(_ replacement: PullRequestTextReplacement) -> Bool {
      let length = (string as NSString).length
      guard isEditable, WindowModalInteraction.allows(self), !hasMarkedText(), string == replacement.expectedText,
        selectedRange() == replacement.selection, replacement.range.location <= length,
        replacement.range.length <= length - replacement.range.location else { return false }
      breakUndoCoalescing()
      insertText(replacement.text, replacementRange: replacement.range)
      setSelectedRange(NSRange(location: replacement.range.location + replacement.text.utf16.count, length: 0))
      breakUndoCoalescing()
      return true
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
