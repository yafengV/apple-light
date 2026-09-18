import SwiftUI

/// A selectable, read-only source view with native focus and selection semantics.
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
    context.coordinator.install(text, store: store, workspace: workspace)
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let text = scroll.documentView as? NSTextView else { return }
    let coordinator = context.coordinator
    let identity = (workspace.root?.path ?? "") + "/" + (workspace.selectedFile ?? "")
    if coordinator.identity != identity {
      coordinator.savePosition(text)
      coordinator.identity = identity
      coordinator.needsRestore = true
    } else if workspace.fileLoading, !coordinator.wasLoading {
      coordinator.savePosition(text)
      coordinator.needsRestore = true
    }
    coordinator.wasLoading = workspace.fileLoading
    let root = (workspace.root?.path ?? "") + "/"
    let open = Set(workspace.openFiles.map { root + $0 })
    workspace.filePreviewPositions = workspace.filePreviewPositions.filter { open.contains($0.key) }
    if text.string != workspace.fileText {
      text.string = workspace.fileText
      text.setSelectedRange(NSRange(location: 0, length: 0))
    }
    text.font = NSFont(name: appearance.codeFont, size: appearance.codeSize)
      ?? .monospacedSystemFont(ofSize: appearance.codeSize, weight: .regular)
    text.textColor = NSColor(appearance.foregroundColor)
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
    coordinator.stop()
  }

  final class Coordinator {
    var identity: String?
    weak var workspace: DeveloperWorkspace?
    var needsRestore = false
    var wasLoading = false
    var focusRequest: UUID?
    var lineRequest: UUID?
    private var monitor: Any?

    @MainActor func savePosition(_ text: NSTextView) {
      guard let identity, !needsRestore, !wasLoading, let workspace,
        let root = workspace.root?.path,
        workspace.openFiles.contains(where: { root + "/" + $0 == identity }) else { return }
      workspace.filePreviewPositions[identity] = FilePreviewPosition(
        selection: text.selectedRange(), origin: text.enclosingScrollView?.contentView.bounds.origin ?? .zero)
    }
    func install(_ text: NSTextView, store: WorkspaceStore, workspace: DeveloperWorkspace) {
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
    func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    deinit { stop() }
  }
}

final class FilePreviewTextView: NSTextView {
  weak var workspace: DeveloperWorkspace?
  var onFocus: (() -> Void)?
  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted { onFocus?() }
    return accepted
  }
}
