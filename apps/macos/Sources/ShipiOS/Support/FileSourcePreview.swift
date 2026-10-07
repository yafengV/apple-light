import SwiftUI

/// A selectable source editor with native focus and selection semantics.
struct FileSourcePreview: NSViewRepresentable {
  let store: WorkspaceStore
  let workspace: DeveloperWorkspace
  var taskID: String? = nil
  var closeContentTab: (() -> Void)? = nil
  @Environment(\.appAppearance) private var appearance

  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    scroll.drawsBackground = false
    let text = FilePreviewTextView(frame: .zero)
    text.workspace = workspace
    text.onFocus = { [weak store] in store?.blurComposer = UUID() }
    text.isEditable = false
    text.isSelectable = true
    text.isRichText = false
    text.isAutomaticQuoteSubstitutionEnabled = false
    text.isAutomaticDashSubstitutionEnabled = false
    text.isAutomaticTextReplacementEnabled = false
    text.isContinuousSpellCheckingEnabled = false
    text.allowsUndo = true
    text.drawsBackground = false
    text.isHorizontallyResizable = true
    text.isVerticallyResizable = true
    text.autoresizingMask = [.width]
    text.textContainerInset = NSSize(width: 12, height: 12)
    text.textContainer?.widthTracksTextView = false
    text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    text.setAccessibilityLabel("文件内容")
    scroll.documentView = text
    text.delegate = context.coordinator
    text.layoutManager?.delegate = context.coordinator.inlineLayout
    workspace.fileFind.bind(editor: text)
    workspace.selectionEdit.bind(editor: text)
    context.coordinator.install(text, store: store, workspace: workspace, taskID: taskID,
      closeContentTab: closeContentTab)
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let text = scroll.documentView as? FilePreviewTextView else { return }
    text.useFontSmoothing = appearance.useFontSmoothing
    workspace.fileFind.bind(editor: text)
    workspace.selectionEdit.bind(editor: text)
    scroll.drawsBackground = true; scroll.backgroundColor = NSColor(appearance.codeBackgroundColor)
    let coordinator = context.coordinator
    coordinator.taskID = taskID
    coordinator.closeContentTab = closeContentTab
    coordinator.appearance = appearance
    // Swift strings compare canonically; the byte revision also observes source
    // changes that look equal but have different UTF-16 positions.
    _ = workspace.fileContentVersion
    let identity = (workspace.root?.path ?? "") + "/" + (workspace.selectedFile ?? "")
    if coordinator.identity != identity {
      coordinator.dismissSelectionAction()
      coordinator.savePosition(text)
      coordinator.identity = identity
      coordinator.needsRestore = true
    } else if workspace.fileLoading, !coordinator.wasLoading {
      coordinator.savePosition(text)
      coordinator.needsRestore = true
    }
    coordinator.wasLoading = workspace.fileLoading
    if workspace.fileLoading || workspace.selectionEdit.isPresented {
      coordinator.dismissSelectionAction()
    }
    let root = (workspace.root?.path ?? "") + "/"
    let open = Set(workspace.openFiles.map { root + $0 })
    workspace.filePreviewPositions = workspace.filePreviewPositions.filter { open.contains($0.key) }
    if !text.string.utf8.elementsEqual(workspace.fileText.utf8) {
      let previousSelection = text.selectedRange()
      coordinator.applyingProgrammaticText = true
      text.string = workspace.fileText
      coordinator.applyingProgrammaticText = false
      let length = (text.string as NSString).length
      let location = min(previousSelection.location, length)
      text.setSelectedRange(NSRange(location: location,
        length: min(previousSelection.length, length - location)))
      if workspace.fileFind.isPresented { workspace.fileFind.refresh(in: text.string, reveal: true) }
    }
    text.isEditable = workspace.selectedFileEditor != nil && !workspace.fileLoading && workspace.fileError == nil
    text.syntax.update(text, path: workspace.selectedFile.map { _ in identity }, source: workspace.fileText,
      ready: !workspace.fileLoading && workspace.fileError == nil && !workspace.fileIsReadOnly,
      appearance: appearance)
    coordinator.syncSelectionEditor(in: text, store: store, workspace: workspace)
    coordinator.positionInlineReview(in: text)
    if !workspace.fileLoading, coordinator.needsRestore {
      coordinator.needsRestore = false
      let position = workspace.filePreviewPositions[identity]
      // A remounted view restores its last selection, not an old line-jump request.
      if position != nil, coordinator.lineRequest == nil { coordinator.lineRequest = workspace.fileLineRequest }
      let length = (text.string as NSString).length
      let range = position?.selection ?? NSRange(location: 0, length: 0)
      text.setSelectedRange(NSRange(location: min(range.location, length), length: min(range.length, max(0, length - range.location))))
      text.layoutManager?.ensureLayout(for: text.textContainer!)
      scroll.contentView.scroll(to: position?.origin ?? .zero)
      scroll.reflectScrolledClipView(scroll.contentView)
    }
    if coordinator.lineRequest != workspace.fileLineRequest {
      coordinator.lineRequest = workspace.fileLineRequest
      if let range = workspace.fileLineRange, NSMaxRange(range) <= (text.string as NSString).length {
        text.setSelectedRange(range)
        text.scrollRangeToVisible(range)
      }
    }
    let request = workspace.fileFocusRequest
    if coordinator.focusRequest != request, !workspace.fileLoading {
      coordinator.focusRequest = request
      DispatchQueue.main.async { [weak text, weak store, weak workspace] in
        guard let text, let store, let workspace,
          workspace.selectedFile != nil, !workspace.fileLoading, workspace.fileError == nil,
          !workspace.showingFileLine, workspace.fileFocusRequest == request, let window = text.window,
          window.isKeyWindow, window.attachedSheet == nil else { return }
        if workspace === store.workspace, !store.fileCommandsAvailable { return }
        // Revalidate after SwiftUI schedules the request: another modal or tab
        // can replace the original source before this native callback runs.
        if window.identifier?.rawValue == "main" {
          guard store.destination == .workspace, store.presentedOverlay == nil,
            !store.hasSettingsConfirmation, store.appshotIntroRequest == nil else { return }
          if workspace !== store.workspace, store.commandFileWorkspace !== workspace { return }
        }
        window.makeFirstResponder(text)
      }
    }
  }

  static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
    if let text = view.documentView as? NSTextView { coordinator.savePosition(text) }
    if let text = view.documentView as? FilePreviewTextView,
      coordinator.workspace?.fileFind.editor === text {
      coordinator.workspace?.fileFind.bind(editor: nil)
    }
    if let text = view.documentView as? FilePreviewTextView,
      coordinator.workspace?.selectionEdit.editor === text {
      coordinator.workspace?.selectionEdit.bind(editor: nil)
    }
    (view.documentView as? FilePreviewTextView)?.syntax.stop()
    coordinator.stop()
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var identity: String?
    weak var workspace: DeveloperWorkspace?
    var needsRestore = false
    var wasLoading = false
    var focusRequest: UUID?
    var lineRequest: UUID?
    var applyingProgrammaticText = false
    private var selectionAction: NSPopover?
    private var selectionActionRange: NSRange?
    private var selectionEditor: NSPopover?
    let inlineLayout = FileSelectionInlineLayout()
    var appearance = AppearancePreferences()
    private var inlineReview: NSHostingView<FileSelectionEditPanel>?
    private weak var inlineText: FilePreviewTextView?
    weak var store: WorkspaceStore?
    var taskID: String?
    var closeContentTab: (() -> Void)?
    private var monitor: Any?

    @MainActor func savePosition(_ text: NSTextView) {
      guard let identity, !needsRestore, !wasLoading, let workspace,
        let root = workspace.root?.path,
        workspace.openFiles.contains(where: { root + "/" + $0 == identity }) else { return }
      workspace.filePreviewPositions[identity] = FilePreviewPosition(
        selection: text.selectedRange(), origin: text.enclosingScrollView?.contentView.bounds.origin ?? .zero)
    }
    func install(_ text: FilePreviewTextView, store: WorkspaceStore, workspace: DeveloperWorkspace,
      taskID: String?, closeContentTab: (() -> Void)? = nil) {
      self.workspace = workspace
      self.store = store
      self.taskID = taskID
      self.closeContentTab = closeContentTab
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
        [weak self, weak text, weak store, weak workspace] event in
        guard let binding = ShortcutBinding(event: event) else { return event }
        let windowNumber = event.windowNumber
        let handled = MainActor.assumeIsolated {
          guard let text, let window = text.window, window.windowNumber == windowNumber,
            window.isKeyWindow, window.firstResponder === text, window.attachedSheet == nil,
            let store, let workspace
          else { return false }
          if store.shortcuts.matches("find", binding) {
            workspace.fileFind.open(editor: text, source: text.string)
            return true
          }
          if binding == ShortcutBinding("⌘⌥F") {
            workspace.fileFind.open(editor: text, replacing: true, source: text.string)
            return true
          }
          if store.shortcuts.matches("find-next", binding), workspace.fileFind.isPresented {
            workspace.fileFind.move(1)
            return true
          }
          if store.shortcuts.matches("find-previous", binding), workspace.fileFind.isPresented {
            workspace.fileFind.move(-1)
            return true
          }
          if binding == ShortcutBinding("⎋"), workspace.fileFind.isPresented {
            workspace.fileFind.close()
            return true
          }
          let sourceCommand: FileTextCommand?
          switch binding {
          case ShortcutBinding("⇥"): sourceCommand = .insertIndent
          case ShortcutBinding("⇧⇥"), ShortcutBinding("⌘["): sourceCommand = .outdentLines
          case ShortcutBinding("⌘]"): sourceCommand = .indentLines
          case ShortcutBinding("⌘/"): sourceCommand = .toggleLineComment
          case ShortcutBinding("⇧⌥a"): sourceCommand = .toggleBlockComment
          case ShortcutBinding("⌥↑"), ShortcutBinding("⌃⌥p"): sourceCommand = .moveUp
          case ShortcutBinding("⌥↓"), ShortcutBinding("⌃⌥n"): sourceCommand = .moveDown
          case ShortcutBinding("⇧⌥↑"): sourceCommand = .copyUp
          case ShortcutBinding("⇧⌥↓"): sourceCommand = .copyDown
          case ShortcutBinding("⌘↵"): sourceCommand = .insertBlankLine
          default: sourceCommand = nil
          }
          if let sourceCommand, text.performSourceCommand(sourceCommand) { return true }
          if binding == ShortcutBinding("⌘S"), workspace.selectedFileEditor != nil {
            Task { await workspace.saveSelectedFileEdits() }
            return true
          }
          if workspace === store.workspace {
            guard store.handleFileShortcut(binding) else { return false }
          } else if binding == ShortcutBinding("⌘W"), let closeContentTab = self?.closeContentTab {
            closeContentTab()
          } else if binding == ShortcutBinding("⌘W"), let path = workspace.selectedFile {
            workspace.closeFile(path)
          } else if store.shortcuts.matches("browser-address", binding) {
            if !workspace.fileLoading, workspace.fileError == nil { workspace.showingFileLine = true }
          } else if store.shortcuts.matches("next-task", binding) {
            if self?.closeContentTab != nil { return false }
            workspace.moveFile(1)
          } else if store.shortcuts.matches("previous-task", binding) {
            if self?.closeContentTab != nil { return false }
            workspace.moveFile(-1)
          } else { return false }
          return true
        }
        return handled ? nil : event
      }
    }
    func stop() {
      dismissSelectionAction()
      dismissSelectionEditor()
      dismissInlineReview()
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
    func dismissSelectionAction() {
      selectionAction?.close()
      selectionAction = nil
      selectionActionRange = nil
    }
    func dismissSelectionEditor() {
      selectionEditor?.close()
      selectionEditor = nil
    }
    func dismissInlineReview() {
      inlineReview?.removeFromSuperview()
      inlineReview = nil
      if let text = inlineText, inlineLayout.anchorGlyph != nil {
        inlineLayout.anchorGlyph = nil
        inlineLayout.anchorIsEOF = false
        invalidateInlineLayout(in: text)
        text.minSize.height = 0
        text.sizeToFit()
      }
      inlineText = nil
    }
    private func invalidateInlineLayout(in text: NSTextView) {
      let length = (text.string as NSString).length
      guard length > 0 else { return }
      text.layoutManager?.invalidateLayout(forCharacterRange: NSRange(location: 0, length: length),
        actualCharacterRange: nil)
      if let container = text.textContainer { text.layoutManager?.ensureLayout(for: container) }
    }
    @MainActor func positionInlineReview(in text: FilePreviewTextView) {
      guard let inlineReview, let glyph = inlineLayout.anchorGlyph,
        let layout = text.layoutManager, let container = text.textContainer,
        glyph < layout.numberOfGlyphs else { return }
      layout.ensureLayout(for: container)
      let line = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
      let origin = text.textContainerOrigin
      inlineReview.frame.origin = NSPoint(x: origin.x + 8, y: origin.y + line.maxY + 2)
      if inlineLayout.anchorIsEOF {
        text.minSize.height = inlineReview.frame.maxY + text.textContainerInset.height + 8
        text.sizeToFit()
      }
    }
    @MainActor private func showInlineReview(in text: FilePreviewTextView, store: WorkspaceStore,
      workspace: DeveloperWorkspace, request: FileSelectionEditRequest, width: CGFloat) {
      let source = text.string as NSString
      guard source.length > 0, NSMaxRange(request.range) <= source.length,
        let layout = text.layoutManager else { return }
      let lastCharacter = NSMaxRange(request.range) - 1
      let line = source.lineRange(for: NSRange(location: lastCharacter, length: 0))
      let anchor = layout.glyphIndexForCharacter(at: min(NSMaxRange(line) - 1, source.length - 1))
      let ending = source.character(at: source.length - 1)
      let anchorIsEOF = NSMaxRange(line) == source.length && ending != 10 && ending != 13
      if inlineLayout.anchorGlyph != anchor || inlineLayout.anchorIsEOF != anchorIsEOF {
        inlineLayout.anchorGlyph = anchor
        inlineLayout.anchorIsEOF = anchorIsEOF
        invalidateInlineLayout(in: text)
      }
      let reviewWidth = min(width, max(320, text.visibleRect.width - 40))
      let created = inlineReview == nil
      if inlineReview == nil {
        let view = NSHostingView(rootView: FileSelectionEditPanel(store: store, workspace: workspace,
          taskID: taskID, onReviewChange: { [weak self, weak text, weak store, weak workspace] _ in
            DispatchQueue.main.async { [weak self, weak text, weak store, weak workspace] in
              guard let self, let text, let store, let workspace else { return }
              self.syncSelectionEditor(in: text, store: store, workspace: workspace)
            }
          }))
        text.addSubview(view)
        inlineReview = view
        inlineText = text
      }
      inlineReview?.frame.size = NSSize(width: reviewWidth, height: FileSelectionInlineLayout.reviewHeight - 8)
      positionInlineReview(in: text)
      if created, let inlineReview { text.scrollToVisible(inlineReview.frame) }
    }
    @MainActor func syncSelectionEditor(in text: FilePreviewTextView, store: WorkspaceStore,
      workspace: DeveloperWorkspace) {
      syncSelectionHighlight(in: text, workspace: workspace)
      guard workspace.selectionEdit.isPresented, let request = workspace.selectionEdit.request,
        workspace.selectedFile == request.path, !workspace.fileLoading,
        NSMaxRange(request.range) <= (text.string as NSString).length,
        let window = text.window else {
        dismissSelectionEditor()
        dismissInlineReview()
        return
      }
      let width = max(320, min(520, window.frame.width - 32))
      if let proposal = workspace.selectionEdit.proposal {
        dismissSelectionEditor()
        if let selected = request.selectedText, proposal.prefersInlineReview(selectedText: selected) {
          showInlineReview(in: text, store: store, workspace: workspace, request: request, width: width)
        } else {
          dismissInlineReview()
        }
        return
      }
      dismissInlineReview()
      if selectionEditor?.isShown == true { return }
      guard let anchor = selectionAnchor(in: text, range: request.range, window: window) else { return }
      let popover = NSPopover()
      popover.behavior = .applicationDefined
      popover.contentSize = NSSize(width: width, height: 170)
      popover.contentViewController = NSHostingController(rootView:
        FileSelectionEditPanel(store: store, workspace: workspace, taskID: taskID,
          onReviewChange: { [weak self, weak text, weak store, weak workspace] _ in
            DispatchQueue.main.async { [weak self, weak text, weak store, weak workspace] in
              guard let self, let text, let store, let workspace else { return }
              self.syncSelectionEditor(in: text, store: store, workspace: workspace)
            }
          }).frame(width: width, alignment: .topLeading))
      selectionEditor = popover
      popover.show(relativeTo: anchor, of: text, preferredEdge: .maxY)
    }
    @MainActor private func syncSelectionHighlight(in text: FilePreviewTextView,
      workspace: DeveloperWorkspace) {
      let session = workspace.selectionEdit
      guard session.isPresented, let request = session.request,
        workspace.selectedFile == request.path, !workspace.fileLoading,
        text.string.utf8.elementsEqual(request.source.utf8),
        text.selectedRange() == request.range,
        NSMaxRange(request.range) <= (text.string as NSString).length else {
        inlineLayout.updateHighlight(in: text, range: nil, color: nil)
        return
      }
      if session.generating {
        inlineLayout.updateHighlight(in: text, range: request.range,
          color: NSColor.systemPurple.withAlphaComponent(0.32))
      } else if let proposal = session.proposal, let selected = request.selectedText,
        proposal.prefersInlineReview(selectedText: selected) {
        inlineLayout.updateHighlight(in: text, range: request.range,
          color: NSColor(appearance.diffRemovedColor).withAlphaComponent(0.28))
      } else {
        inlineLayout.updateHighlight(in: text, range: nil, color: nil)
      }
    }
    func textDidChange(_ notification: Notification) {
      guard !applyingProgrammaticText, let text = notification.object as? FilePreviewTextView,
        let workspace, workspace.selectedFileEditor != nil,
        !text.string.utf8.elementsEqual(workspace.fileText.utf8) else { return }
      workspace.editSelectedFile(text.string)
      syncSelectionHighlight(in: text, workspace: workspace)
    }
    func textViewDidChangeSelection(_ notification: Notification) {
      guard let text = notification.object as? FilePreviewTextView, let workspace else { return }
      workspace.selectionEdit.selectionChanged(in: text)
      syncSelectionHighlight(in: text, workspace: workspace)
      updateSelectionAction(in: text, workspace: workspace)
    }
    @MainActor private func updateSelectionAction(in text: FilePreviewTextView, workspace: DeveloperWorkspace) {
      guard let range = workspace.selectionEdit.candidate, !workspace.selectionEdit.isPresented,
        let path = workspace.selectedFile, text.isEditable,
        let window = text.window, window.isKeyWindow, window.firstResponder === text else {
        dismissSelectionAction()
        return
      }
      if selectionAction?.isShown == true, selectionActionRange == range { return }
      selectionAction?.close()
      guard let anchor = selectionAnchor(in: text, range: range, window: window) else { return }
      let popover = NSPopover()
      popover.behavior = .transient
      popover.contentSize = NSSize(width: 160, height: 42)
      popover.contentViewController = NSHostingController(rootView:
        Button("编辑选区…") { [weak self, weak popover, weak workspace, weak text] in
          if let workspace, workspace.selectedFile == path {
            workspace.selectionEdit.open(path: path, source: workspace.fileText)
          }
          popover?.close()
          self?.dismissSelectionAction()
          DispatchQueue.main.async { [weak self, weak text, weak workspace] in
            guard let self, let text, let workspace, let store = self.store else { return }
            self.syncSelectionEditor(in: text, store: store, workspace: workspace)
          }
        }.buttonStyle(.plain).padding(10).frame(maxWidth: .infinity, alignment: .leading))
      selectionAction = popover
      selectionActionRange = range
      popover.show(relativeTo: anchor, of: text, preferredEdge: .maxY)
    }
    @MainActor private func selectionAnchor(in text: FilePreviewTextView, range: NSRange,
      window: NSWindow) -> NSRect? {
      guard range.length > 0 else { return nil }
      let trailing = NSRange(location: NSMaxRange(range) - 1, length: 1)
      let screenRect = text.firstRect(forCharacterRange: trailing, actualRange: nil)
      guard !screenRect.isEmpty else { return nil }
      return text.convert(window.convertFromScreen(screenRect), from: nil)
    }
    deinit { stop() }
  }
}

/// Reserves a line-height-independent review slot without changing the file's text storage.
final class FileSelectionInlineLayout: NSObject, NSLayoutManagerDelegate {
  static let reviewHeight: CGFloat = 276
  var anchorGlyph: Int?
  var anchorIsEOF = false
  private(set) var highlightRange: NSRange?
  private var highlightColor: NSColor?
  private var originalSelectionAttributes: [NSAttributedString.Key: Any]?

  func updateHighlight(in text: NSTextView, range: NSRange?, color: NSColor?) {
    let previous = highlightRange
    if previous == range,
      (highlightColor == nil && color == nil || highlightColor?.isEqual(color) == true) { return }
    if let color, range == text.selectedRange() {
      if originalSelectionAttributes == nil { originalSelectionAttributes = text.selectedTextAttributes }
      var attributes = originalSelectionAttributes ?? text.selectedTextAttributes
      attributes[.backgroundColor] = color
      attributes[.foregroundColor] = NSColor.labelColor
      text.selectedTextAttributes = attributes
    } else if let originalSelectionAttributes {
      text.selectedTextAttributes = originalSelectionAttributes
      self.originalSelectionAttributes = nil
    }
    highlightRange = range
    highlightColor = color
    if let previous { text.layoutManager?.invalidateDisplay(forCharacterRange: previous) }
    if let range { text.layoutManager?.invalidateDisplay(forCharacterRange: range) }
  }

  func layoutManager(_ layoutManager: NSLayoutManager,
    shouldUseTemporaryAttributes attrs: [NSAttributedString.Key: Any], forDrawingToScreen toScreen: Bool,
    atCharacterIndex charIndex: Int, effectiveRange effectiveCharRange: NSRangePointer?)
    -> [NSAttributedString.Key: Any]? {
    guard toScreen else { return nil }
    guard let highlightRange, let highlightColor else { return attrs }
    if let effectiveCharRange {
      let current = effectiveCharRange.pointee
      if charIndex < highlightRange.location {
        effectiveCharRange.pointee = NSRange(location: current.location,
          length: min(NSMaxRange(current), highlightRange.location) - current.location)
      } else if charIndex >= NSMaxRange(highlightRange) {
        let location = max(current.location, NSMaxRange(highlightRange))
        effectiveCharRange.pointee = NSRange(location: location, length: NSMaxRange(current) - location)
      } else {
        effectiveCharRange.pointee = NSIntersectionRange(current, highlightRange)
      }
    }
    guard NSLocationInRange(charIndex, highlightRange) else { return attrs }
    var colored = attrs
    colored[.backgroundColor] = highlightColor
    return colored
  }

  func layoutManager(_ layoutManager: NSLayoutManager, paragraphSpacingAfterGlyphAt glyphIndex: Int,
    withProposedLineFragmentRect rect: NSRect) -> CGFloat {
    glyphIndex == anchorGlyph ? Self.reviewHeight + 12 : 0
  }

  func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
    lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
    in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
    guard anchorIsEOF, let anchorGlyph, NSLocationInRange(anchorGlyph, glyphRange) else { return false }
    lineFragmentRect.pointee.size.height += Self.reviewHeight + 12
    return true
  }
}

final class FilePreviewTextView: AppearanceTextView {
  let syntax = FilePreviewSyntaxController()
  weak var workspace: DeveloperWorkspace?
  var onFocus: (() -> Void)?
  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted { onFocus?() }
    return accepted
  }

  @discardableResult func performSourceCommand(_ command: FileTextCommand) -> Bool {
    guard isEditable, let path = workspace?.selectedFile,
      let edit = FileTextCommands.edit(command, in: string, selection: selectedRange(), path: path) else {
      return false
    }
    insertText(edit.replacement, replacementRange: edit.range)
    let length = (string as NSString).length
    guard NSMaxRange(edit.selection) <= length else { return true }
    setSelectedRange(edit.selection)
    scrollRangeToVisible(edit.selection)
    return true
  }
}
