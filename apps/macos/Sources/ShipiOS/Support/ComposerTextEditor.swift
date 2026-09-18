import AppKit
import SwiftUI

enum ComposerEditorKey {
  case up, down, enter, tab, escape
}

enum ComposerTextStyle: Equatable {
  case heading(Int)
  case listMarker
  case codeBlock
  case inlineCode
  case strong
  case emphasis
  case link(URL)
}

struct ComposerTextStyleSpan: Equatable {
  let range: NSRange
  let style: ComposerTextStyle
}

enum ComposerTextStylePlan {
  static func spans(in source: String) -> [ComposerTextStyleSpan] {
    let full = NSRange(source.startIndex..<source.endIndex, in: source)
    var spans: [ComposerTextStyleSpan] = []
    matches(#"(?m)^(#{1,6})\s+.*$"#, in: source, range: full).forEach { match in
      spans.append(.init(range: match.range, style: .heading(match.range(at: 1).length)))
    }
    matches(#"(?m)^\s*(?:[-+*]|\d+[.)])\s+"#, in: source, range: full).forEach {
      spans.append(.init(range: $0.range, style: .listMarker))
    }
    matches(#"(?s)```(?:[^\n]*)\n?.*?(?:```|$)"#, in: source, range: full).forEach {
      spans.append(.init(range: $0.range, style: .codeBlock))
    }
    matches(#"`[^`\n]+`"#, in: source, range: full).forEach {
      spans.append(.init(range: $0.range, style: .inlineCode))
    }
    matches(#"\*\*[^*\n]+\*\*|__[^_\n]+__"#, in: source, range: full).forEach {
      spans.append(.init(range: $0.range, style: .strong))
    }
    matches(#"(?<!\*)\*[^*\n]+\*(?!\*)|(?<!_)_[^_\n]+_(?!_)"#, in: source, range: full).forEach {
      spans.append(.init(range: $0.range, style: .emphasis))
    }
    matches(#"\[[^\]\n]+\]\((https?://[^\s)]+)\)"#, in: source, range: full).forEach { match in
      guard let range = Range(match.range(at: 1), in: source),
        let url = URL(string: String(source[range])) else { return }
      spans.append(.init(range: match.range, style: .link(url)))
    }
    matches(#"(?<!\]\()https?://[^\s<>]+"#, in: source, range: full).forEach { match in
      guard let range = Range(match.range, in: source),
        let url = URL(string: String(source[range])) else { return }
      spans.append(.init(range: match.range, style: .link(url)))
    }
    return spans
  }

  static func continuation(after line: String) -> String? {
    guard let match = matches(#"^(\s*)([-+*]|\d+[.)])\s+(.+)$"#, in: line,
      range: NSRange(line.startIndex..<line.endIndex, in: line)).first,
      let indentRange = Range(match.range(at: 1), in: line),
      let markerRange = Range(match.range(at: 2), in: line)
    else { return nil }
    let indent = String(line[indentRange])
    let marker = String(line[markerRange])
    if let number = Int(marker.dropLast()), let suffix = marker.last {
      return "\(indent)\(number + 1)\(suffix) "
    }
    return "\(indent)\(marker) "
  }

  static func isEmptyListItem(_ line: String) -> Bool {
    matches(#"^\s*(?:[-+*]|\d+[.)])\s*$"#, in: line,
      range: NSRange(line.startIndex..<line.endIndex, in: line)).first != nil
  }

  private static func matches(
    _ pattern: String, in source: String, range: NSRange
  ) -> [NSTextCheckingResult] {
    (try? NSRegularExpression(pattern: pattern))?.matches(in: source, range: range) ?? []
  }
}

struct ComposerTextEditor: NSViewRepresentable {
  @Binding var text: String
  @Binding var focused: Bool
  let plainTextMode: Bool
  let placeholder: String
  let accessibilityLabel: String
  let focusRequest: UUID
  let onKey: (ComposerEditorKey, NSEvent.ModifierFlags, Bool) -> Bool
  let onPasteAttachments: ([NSItemProvider]) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.borderType = .noBorder
    let editor = ComposerNativeTextView()
    editor.delegate = context.coordinator
    editor.coordinator = context.coordinator
    editor.placeholder = placeholder
    editor.isRichText = true
    editor.importsGraphics = false
    editor.allowsUndo = true
    editor.drawsBackground = false
    editor.isHorizontallyResizable = false
    editor.isVerticallyResizable = true
    editor.textContainer?.widthTracksTextView = true
    editor.textContainerInset = NSSize(width: 0, height: 5)
    editor.setAccessibilityLabel(accessibilityLabel)
    scroll.documentView = editor
    context.coordinator.install(text, in: editor)
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let editor = scroll.documentView as? ComposerNativeTextView else { return }
    context.coordinator.parent = self
    editor.placeholder = placeholder
    context.coordinator.sync(text, plainTextMode: plainTextMode, in: editor)
    if context.coordinator.focusRequest != focusRequest {
      context.coordinator.focusRequest = focusRequest
      DispatchQueue.main.async { editor.window?.makeFirstResponder(editor) }
    } else if focused, editor.window?.firstResponder !== editor {
      DispatchQueue.main.async { editor.window?.makeFirstResponder(editor) }
    } else if !focused, editor.window?.firstResponder === editor {
      editor.window?.makeFirstResponder(nil)
    }
  }

  @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: ComposerTextEditor
    var focusRequest: UUID
    private var applying = false
    init(_ parent: ComposerTextEditor) {
      self.parent = parent
      focusRequest = parent.focusRequest
    }

    func install(_ value: String, in editor: NSTextView) {
      editor.string = value
      applyStyles(in: editor)
    }

    func sync(_ value: String, plainTextMode: Bool, in editor: NSTextView) {
      guard !applying, !editor.hasMarkedText() else { return }
      if editor.string != value {
        let selection = editor.selectedRanges
        editor.string = value
        editor.selectedRanges = selection.map { item in
          let range = item.rangeValue
          return NSValue(range: NSRange(location: min(range.location, editor.string.utf16.count), length: 0))
        }
      }
      applyStyles(in: editor)
    }

    func textDidBeginEditing(_ notification: Notification) {
      if !parent.focused { parent.focused = true }
    }

    func textDidEndEditing(_ notification: Notification) {
      if parent.focused { parent.focused = false }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
      guard !applying, let editor = notification.object as? NSTextView,
        !editor.hasMarkedText(), !parent.plainTextMode else { return }
      applyStyles(in: editor)
    }

    func textDidChange(_ notification: Notification) {
      guard !applying, let editor = notification.object as? NSTextView else { return }
      guard !editor.hasMarkedText() else { return }
      parent.text = editor.string
      applyStyles(in: editor)
      editor.needsDisplay = true
    }

    func applyStyles(in editor: NSTextView) {
      guard let storage = editor.textStorage else { return }
      let selected = editor.selectedRanges
      let full = NSRange(location: 0, length: storage.length)
      applying = true
      storage.beginEditing()
      storage.setAttributes([
        .font: NSFont.systemFont(ofSize: 14),
        .foregroundColor: NSColor.labelColor,
      ], range: full)
      if !parent.plainTextMode {
        let cursor = editor.selectedRange().location
        for span in ComposerTextStylePlan.spans(in: storage.string) where NSMaxRange(span.range) <= storage.length {
          let editingSpan = NSLocationInRange(cursor, span.range)
          switch span.style {
          case .heading(let level):
            storage.addAttributes([
              .font: NSFont.systemFont(ofSize: max(15, 22 - CGFloat(level)), weight: .semibold),
            ], range: span.range)
            if !editingSpan {
              conceal(NSRange(location: span.range.location, length: min(level + 1, span.range.length)), in: storage)
            }
          case .listMarker:
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: span.range)
          case .codeBlock:
            storage.addAttributes([
              .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
              .backgroundColor: NSColor.quaternaryLabelColor,
            ], range: span.range)
            if !editingSpan { concealCodeFences(span.range, in: storage) }
          case .inlineCode:
            storage.addAttributes([
              .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
              .backgroundColor: NSColor.quaternaryLabelColor,
            ], range: span.range)
            if !editingSpan { concealEdges(of: span.range, count: 1, in: storage) }
          case .strong:
            storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 14, weight: .bold), range: span.range)
            if !editingSpan { concealEdges(of: span.range, count: 2, in: storage) }
          case .emphasis:
            storage.addAttribute(.obliqueness, value: 0.18, range: span.range)
            if !editingSpan { concealEdges(of: span.range, count: 1, in: storage) }
          case .link(let url):
            styleLink(url, span: span.range, editing: editingSpan, in: storage)
          }
        }
      }
      storage.endEditing()
      editor.selectedRanges = selected
      editor.typingAttributes = [
        .font: NSFont.systemFont(ofSize: 14),
        .foregroundColor: NSColor.labelColor,
      ]
      applying = false
    }

    private func concealEdges(of range: NSRange, count: Int, in storage: NSTextStorage) {
      guard range.length >= count * 2 else { return }
      conceal(NSRange(location: range.location, length: count), in: storage)
      conceal(NSRange(location: NSMaxRange(range) - count, length: count), in: storage)
    }

    private func conceal(_ range: NSRange, in storage: NSTextStorage) {
      guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
      storage.addAttributes([
        .font: NSFont.systemFont(ofSize: 0.1),
        .foregroundColor: NSColor.clear,
      ], range: range)
    }

    private func concealCodeFences(_ range: NSRange, in storage: NSTextStorage) {
      let value = storage.string as NSString
      let source = value.substring(with: range) as NSString
      let openingEnd = source.range(of: "\n").location
      let openingLength = openingEnd == NSNotFound ? min(3, range.length) : openingEnd + 1
      conceal(NSRange(location: range.location, length: openingLength), in: storage)
      let closing = source.range(of: "```", options: .backwards)
      if closing.location != NSNotFound, closing.location > 0 {
        conceal(NSRange(location: range.location + closing.location, length: closing.length), in: storage)
      }
    }

    private func styleLink(
      _ url: URL, span range: NSRange, editing: Bool, in storage: NSTextStorage
    ) {
      let source = (storage.string as NSString).substring(with: range) as NSString
      let closingLabel = source.range(of: "](")
      let markdown = source.hasPrefix("[") && closingLabel.location != NSNotFound
      let visible = markdown
        ? NSRange(location: range.location + 1, length: max(0, closingLabel.location - 1))
        : range
      storage.addAttributes([
        .link: url,
        .foregroundColor: NSColor.linkColor,
        .underlineStyle: NSUnderlineStyle.single.rawValue,
      ], range: visible)
      if markdown, !editing {
        conceal(NSRange(location: range.location, length: 1), in: storage)
        conceal(NSRange(
          location: range.location + closingLabel.location,
          length: range.length - closingLabel.location), in: storage)
      }
    }

    func handle(_ event: NSEvent, in editor: ComposerNativeTextView) -> Bool {
      let key: ComposerEditorKey?
      switch event.keyCode {
      case 126: key = .up
      case 125: key = .down
      case 36, 76: key = .enter
      case 48: key = .tab
      case 53: key = .escape
      default: key = nil
      }
      guard let key else { return false }
      let modifiers = event.modifierFlags.intersection([.shift, .command, .control, .option])
      if parent.onKey(key, modifiers, editor.hasMarkedText()) { return true }
      if key == .enter, modifiers.isEmpty, !parent.plainTextMode {
        let line = currentLine(in: editor)
        if ComposerTextStylePlan.isEmptyListItem(line.text) {
          editor.insertText("", replacementRange: line.range)
          return true
        }
        if let prefix = ComposerTextStylePlan.continuation(after: line.text) {
          editor.insertNewline(nil)
          editor.insertText(prefix, replacementRange: editor.selectedRange())
          return true
        }
      }
      return false
    }

    func paste(in editor: ComposerNativeTextView) -> Bool {
      let board = NSPasteboard.general
      var providers: [NSItemProvider] = []
      if let urls = board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
        providers.append(contentsOf: urls.compactMap { NSItemProvider(contentsOf: $0) })
      }
      if providers.isEmpty, let images = board.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] {
        providers.append(contentsOf: images.map { NSItemProvider(object: $0) })
      }
      if !providers.isEmpty {
        parent.onPasteAttachments(providers)
        return true
      }
      if !parent.plainTextMode, editor.selectedRange().length > 0,
        let value = board.string(forType: .string),
        let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? "")
      {
        let selected = (editor.string as NSString).substring(with: editor.selectedRange())
        editor.insertText("[\(selected)](\(url.absoluteString))", replacementRange: editor.selectedRange())
        return true
      }
      return false
    }

    private func currentLine(in editor: NSTextView) -> (text: String, range: NSRange) {
      let source = editor.string as NSString
      let cursor = min(editor.selectedRange().location, source.length)
      let prefix = source.substring(to: cursor) as NSString
      let start = prefix.range(of: "\n", options: .backwards).location
      let location = start == NSNotFound ? 0 : start + 1
      return (prefix.substring(from: location), NSRange(location: location, length: cursor - location))
    }
  }
}

final class ComposerNativeTextView: NSTextView {
  weak var coordinator: ComposerTextEditor.Coordinator?
  var placeholder = ""

  override func keyDown(with event: NSEvent) {
    if coordinator?.handle(event, in: self) == true { return }
    super.keyDown(with: event)
  }

  override func paste(_ sender: Any?) {
    if coordinator?.paste(in: self) == true { return }
    super.paste(sender)
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard string.isEmpty, !placeholder.isEmpty else { return }
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 14),
      .foregroundColor: NSColor.placeholderTextColor,
    ]
    placeholder.draw(at: NSPoint(x: textContainerInset.width + 1, y: textContainerInset.height),
      withAttributes: attributes)
  }
}
