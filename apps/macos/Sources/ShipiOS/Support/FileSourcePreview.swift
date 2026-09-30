import SwiftUI

/// A selectable source editor with native focus and selection semantics.
struct FileSourcePreview: NSViewRepresentable {
  let store: WorkspaceStore
  let workspace: DeveloperWorkspace
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
    workspace.fileFind.bind(editor: text)
    workspace.selectionEdit.bind(editor: text)
    context.coordinator.install(text, store: store, workspace: workspace)
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let text = scroll.documentView as? FilePreviewTextView else { return }
    workspace.fileFind.bind(editor: text)
    workspace.selectionEdit.bind(editor: text)
    scroll.drawsBackground = true; scroll.backgroundColor = NSColor(appearance.codeBackgroundColor)
    let coordinator = context.coordinator
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
    private var monitor: Any?

    @MainActor func savePosition(_ text: NSTextView) {
      guard let identity, !needsRestore, !wasLoading, let workspace,
        let root = workspace.root?.path,
        workspace.openFiles.contains(where: { root + "/" + $0 == identity }) else { return }
      workspace.filePreviewPositions[identity] = FilePreviewPosition(
        selection: text.selectedRange(), origin: text.enclosingScrollView?.contentView.bounds.origin ?? .zero)
    }
    func install(_ text: FilePreviewTextView, store: WorkspaceStore, workspace: DeveloperWorkspace) {
      self.workspace = workspace
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
        [weak text, weak store, weak workspace] event in
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
          } else if binding == ShortcutBinding("⌘W"), let path = workspace.selectedFile {
            workspace.closeFile(path)
          } else if store.shortcuts.matches("browser-address", binding) {
            if !workspace.fileLoading, workspace.fileError == nil { workspace.showingFileLine = true }
          } else if store.shortcuts.matches("next-task", binding) {
            workspace.moveFile(1)
          } else if store.shortcuts.matches("previous-task", binding) {
            workspace.moveFile(-1)
          } else { return false }
          return true
        }
        return handled ? nil : event
      }
    }
    func stop() {
      dismissSelectionAction()
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
    func dismissSelectionAction() {
      selectionAction?.close()
      selectionAction = nil
      selectionActionRange = nil
    }
    func textDidChange(_ notification: Notification) {
      guard !applyingProgrammaticText, let text = notification.object as? NSTextView,
        let workspace, workspace.selectedFileEditor != nil,
        !text.string.utf8.elementsEqual(workspace.fileText.utf8) else { return }
      workspace.editSelectedFile(text.string)
    }
    func textViewDidChangeSelection(_ notification: Notification) {
      guard let text = notification.object as? FilePreviewTextView, let workspace else { return }
      workspace.selectionEdit.selectionChanged(in: text)
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
      let screenRect = text.firstRect(forCharacterRange: range, actualRange: nil)
      guard !screenRect.isEmpty else { return }
      let anchor = text.convert(window.convertFromScreen(screenRect), from: nil)
      let popover = NSPopover()
      popover.behavior = .transient
      popover.contentSize = NSSize(width: 160, height: 42)
      popover.contentViewController = NSHostingController(rootView:
        Button("编辑选区…") { [weak popover, weak workspace] in
          if let workspace, workspace.selectedFile == path {
            workspace.selectionEdit.open(path: path, source: workspace.fileText)
          }
          popover?.close()
        }.buttonStyle(.plain).padding(10).frame(maxWidth: .infinity, alignment: .leading))
      selectionAction = popover
      selectionActionRange = range
      popover.show(relativeTo: anchor, of: text, preferredEdge: .maxY)
    }
    deinit { stop() }
  }
}

final class FilePreviewTextView: NSTextView {
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
