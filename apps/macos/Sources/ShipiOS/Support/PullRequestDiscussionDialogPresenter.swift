import AppKit
import SwiftUI

struct PullRequestDiscussionDialogPresenter: NSViewRepresentable {
  @Bindable var state: GitHubPRDiscussionState
  let request: GitHubPullRequest
  let writable: Bool
  let valid: () -> Bool
  let submitReview: () -> Void
  let confirmReview: () -> Void
  let deleteComment: (GitHubPRComment) -> Void
  var reportDeleteError: (String) -> Void = { _ in }
  @Environment(\.appAppearance) private var appearance
  @Environment(\.colorScheme) private var colorScheme

  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> WindowDialogHost.Anchor {
    let anchor = WindowDialogHost.Anchor(); anchor.host = context.coordinator.host; return anchor
  }
  func updateNSView(_ anchor: WindowDialogHost.Anchor, context: Context) {
    let owner = context.coordinator; owner.parent = self
    var resolved = appearance
    if resolved.theme == "system" { resolved.theme = colorScheme == .dark ? "dark" : "light" }
    owner.preferences = resolved
    // Observe the form and operation state in this SwiftUI update, then apply
    // native changes without replacing the text view or its editor history.
    _ = state.showingReview; _ = state.deleteTarget; _ = state.reviewBody; _ = state.reviewDecision
    _ = state.busy; _ = state.pendingOwner; _ = state.uncertain; _ = state.readError
    _ = state.snapshot; _ = state.message(for: .review)
    if let target = state.deleteTarget { _ = state.message(for: .delete(target.id)) }
    owner.host.update(anchor)
    if let form = owner.host.surface as? Surface { owner.configure(form) }
  }
  static func dismantleNSView(_ anchor: WindowDialogHost.Anchor, coordinator: Coordinator) {
    anchor.host = nil; coordinator.stop()
  }
  enum Mode: Equatable {
    case review, delete(GitHubPRComment)
    var identity: String {
      switch self { case .review: "review"; case .delete(let comment): "delete:\(comment.kind.rawValue):\(comment.id)" }
    }
  }
  typealias ActionButton = PullRequestMergeDialogPresenter.Button

  final class DecisionControl: NSButton {
    var preferences = AppearancePreferences()
    var available: () -> Bool = { false }
    var select: () -> Void = {}
    override init(frame: NSRect) {
      super.init(frame: frame); setButtonType(.radio); isBordered = false; target = self; action = #selector(pressed)
      focusRingType = .none
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { isEnabled && available() && !isHiddenOrHasHiddenAncestor && WindowModalInteraction.allows(self) }
    override var canBecomeKeyView: Bool { acceptsFirstResponder && window != nil }
    @objc private func pressed() { guard acceptsFirstResponder, window != nil else { return }; select() }
    override func accessibilityPerformPress() -> Bool { guard acceptsFirstResponder, window != nil else { return false }; select(); return true }
    override func mouseDown(with event: NSEvent) {
      guard acceptsFirstResponder else { return }; window?.makeFirstResponder(self); super.mouseDown(with: event)
    }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }
    override func draw(_ dirtyRect: NSRect) {
      let alpha: Double = isEnabled ? 1 : 0.4, roles = preferences.resolvedColors
      let circle = NSBezierPath(ovalIn: .init(x: 1, y: bounds.midY - 6, width: 12, height: 12))
      roles["borderHeavy"].opacity(alpha).nativeColor.setStroke(); circle.lineWidth = 1; circle.stroke()
      if state == .on {
        NSColor.controlAccentColor.withAlphaComponent(alpha).setFill()
        NSBezierPath(ovalIn: .init(x: 4, y: bounds.midY - 3, width: 6, height: 6)).fill()
      }
      let text = NSAttributedString(string: title, attributes: [.font: font ?? .systemFont(ofSize: 13),
        .foregroundColor: roles["textForeground"].opacity(alpha).nativeColor])
      text.draw(at: .init(x: 22, y: (bounds.height - text.size().height) / 2))
      if window?.firstResponder === self {
        roles["borderFocus"].nativeColor.setStroke()
        let focus = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        focus.lineWidth = 1.5; focus.stroke()
      }
    }
    override func resetCursorRects() {
      super.resetCursorRects(); if preferences.usePointerCursors && acceptsFirstResponder { addCursorRect(bounds, cursor: .pointingHand) }
    }
  }
  final class TextView: NSTextView {
    var available: () -> Bool = { false }
    var placeholder = "添加评论…" { didSet { needsDisplay = true } }
    override var acceptsFirstResponder: Bool { isEditable && available() && super.acceptsFirstResponder && WindowModalInteraction.allows(self) }
    override var canBecomeKeyView: Bool { acceptsFirstResponder && window != nil }
    override func draw(_ dirtyRect: NSRect) {
      super.draw(dirtyRect)
      if string.isEmpty {
        NSAttributedString(string: placeholder, attributes: [.font: font ?? .systemFont(ofSize: 13),
          .foregroundColor: NSColor.secondaryLabelColor]).draw(at: .init(x: textContainerInset.width + 5, y: textContainerInset.height))
      }
    }
    override func becomeFirstResponder() -> Bool { let result = super.becomeFirstResponder(); superview?.superview?.needsDisplay = true; return result }
    override func resignFirstResponder() -> Bool { let result = super.resignFirstResponder(); superview?.superview?.needsDisplay = true; return result }
    override func keyDown(with event: NSEvent) { guard isEditable && available() else { return }; super.keyDown(with: event) }
  }
  final class ResizeHandle: NSView {
    weak var form: Surface?
    override func resetCursorRects() { if form?.editor.isEditable == true { addCursorRect(bounds, cursor: .resizeUpDown) } }
    override func draw(_ dirtyRect: NSRect) {
      NSColor.secondaryLabelColor.setStroke()
      for offset: CGFloat in [3, 6, 9] {
        let line = NSBezierPath(); line.move(to: .init(x: bounds.maxX - offset, y: 2))
        line.line(to: .init(x: bounds.maxX - 2, y: offset)); line.lineWidth = 0.8; line.stroke()
      }
    }
    override func mouseDown(with event: NSEvent) {
      guard let form, form.editor.isEditable, form.host?.canAct() == true, let window else { return }
      let start = form.convert(event.locationInWindow, from: nil), height = form.editorHeight
      while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
        if next.type == .leftMouseUp { break }
        guard form.host?.canAct() == true, form.editor.isEditable else { break }
        let point = form.convert(next.locationInWindow, from: nil)
        form.resizeEditor(height + point.y - start.y); form.layoutSubtreeIfNeeded()
      }
    }
  }

  final class Surface: WindowDialogSurface {
    let mode: Mode
    weak var owner: Coordinator?
    var preferences = AppearancePreferences()
    let title = NSTextField(labelWithString: ""), subtitle = NSTextField(wrappingLabelWithString: "")
    let decisionLabel = NSTextField(labelWithString: "审查结果"), commentLabel = NSTextField(labelWithString: "审查评论")
    let decisions = GitHubPRReviewDecision.allCases.map { _ in DecisionControl() }
    let scroll = NSScrollView(), editor = TextView(), resize = ResizeHandle()
    let error = NSTextField(wrappingLabelWithString: ""), errorScroll = NSScrollView()
    let cancel = ActionButton(), submit = ActionButton(), progress = NSProgressIndicator()
    private(set) var editorHeight: CGFloat = 96
    private var panelFrame: NSRect = .zero, errorFrame: NSRect = .zero
    override var dialogFrame: NSRect { panelFrame }
    override var focusTargets: [NSView] {
      var result: [NSView] = []
      if mode == .review {
        result += decisions.filter { $0.state == .on && $0.acceptsFirstResponder }
        if editor.acceptsFirstResponder { result.append(editor) }
      }
      result += [cancel, submit].filter { $0.acceptsFirstResponder }
      return result
    }
    override var initialFocus: NSView? { mode == .review && editor.acceptsFirstResponder ? editor : focusTargets.first }
    init(frame: NSRect, mode: Mode) {
      self.mode = mode; super.init(frame: frame)
      setAccessibilityRole(.group); setAccessibilitySubrole(.dialog); setAccessibilityModal(true)
      setAccessibilityIdentifier(mode == .review ? "pull-request-review-dialog" : "pull-request-delete-dialog")
      title.stringValue = mode == .review ? "提交审查" : "删除评论"
      subtitle.stringValue = mode == .review ? "仅当当前显示的头提交仍然匹配时，才会提交审查。" : "此评论将从 GitHub 永久删除。"
      setAccessibilityLabel(title.stringValue); title.setAccessibilityElement(false)
      cancel.title = "取消"; submit.title = mode == .review ? "提交审查" : "删除评论"
      submit.style = mode == .review ? .primary : .danger
      cancel.setAccessibilityIdentifier("pr-discussion-cancel"); submit.setAccessibilityIdentifier("pr-discussion-submit")
      for (index, decision) in GitHubPRReviewDecision.allCases.enumerated() {
        decisions[index].title = decision.label; decisions[index].setAccessibilityIdentifier("pr-review-" + decision.rawValue)
        addSubview(decisions[index])
      }
      scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
      editor.isRichText = false; editor.allowsUndo = true; editor.drawsBackground = false
      editor.isHorizontallyResizable = false; editor.isVerticallyResizable = true
      editor.textContainer?.widthTracksTextView = true; editor.textContainerInset = .init(width: 5, height: 8)
      editor.setAccessibilityLabel("审查评论"); editor.setAccessibilityIdentifier("pr-review-body")
      scroll.documentView = editor; resize.form = self; resize.setAccessibilityElement(false)
      error.isSelectable = true; error.setAccessibilityIdentifier("pr-review-error")
      errorScroll.drawsBackground = false; errorScroll.hasVerticalScroller = true; errorScroll.autohidesScrollers = true; errorScroll.documentView = error
      progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false; progress.setAccessibilityElement(false)
      for view in [title, subtitle, decisionLabel, commentLabel, scroll, resize, errorScroll, cancel, submit, progress] { addSubview(view) }
      let review = mode == .review
      for view in decisions + [decisionLabel, commentLabel, scroll, resize] { view.isHidden = !review }
      errorScroll.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func height(_ field: NSTextField, width: CGFloat) -> CGFloat {
      max(18, ceil(field.cell?.cellSize(forBounds: .init(x: 0, y: 0, width: width, height: 10_000)).height ?? 18))
    }
    func resizeEditor(_ value: CGFloat) {
      let chrome = dialogFrame.height > 0 ? dialogFrame.height - editorHeight : 348
      editorHeight = max(96, min(max(96, bounds.height - 24 - chrome), value)); needsLayout = true
    }
    override func layout() {
      super.layout()
      let width = min(mode == .review ? 600 : 520, max(0, bounds.width - 40)), inner = max(0, width - 40)
      let subtitleHeight = height(subtitle, width: inner)
      var radioRects: [NSRect] = [], x: CGFloat = 0, row: CGFloat = 0
      for radio in decisions {
        let itemWidth = ceil((radio.title as NSString).size(withAttributes: [.font: radio.font ?? .systemFont(ofSize: 13)]).width) + 26
        if x > 0 && x + itemWidth > inner { x = 0; row += 30 }
        radioRects.append(.init(x: x, y: row, width: itemWidth, height: 18)); x += itemWidth + 12
      }
      let radioHeight = row + 18
      let errorHeight = errorScroll.isHidden ? 0 : min(120, height(error, width: max(0, inner - 24))) + 20
      let chrome = 20 + 18 + 12 + radioHeight + 16 + 18 + 8 + (errorHeight > 0 ? 16 + errorHeight : 0)
      let headerFooter = 40 + 28 + 4 + subtitleHeight + 20 + 28
      if mode == .review { editorHeight = max(96, min(editorHeight, bounds.height - 24 - headerFooter - chrome)) }
      let reviewHeight = mode == .review ? chrome + editorHeight : 0
      let total = headerFooter + reviewHeight
      panelFrame = .init(x: (bounds.width - width) / 2, y: max(12, (bounds.height - total) / 2), width: width, height: total)
      var y = panelFrame.minY + 20
      title.frame = .init(x: panelFrame.minX + 20, y: y, width: inner, height: 28); y += 32
      subtitle.frame = .init(x: title.frame.minX, y: y, width: inner, height: subtitleHeight); y += subtitleHeight
      if mode == .review {
        y += 20; decisionLabel.frame = .init(x: title.frame.minX, y: y, width: inner, height: 18); y += 30
        for (index, rect) in radioRects.enumerated() { decisions[index].frame = rect.offsetBy(dx: title.frame.minX, dy: y) }; y += radioHeight + 16
        commentLabel.frame = .init(x: title.frame.minX, y: y, width: inner, height: 18); y += 26
        scroll.frame = .init(x: title.frame.minX, y: y, width: inner, height: editorHeight)
        editor.minSize = .init(width: 0, height: editorHeight); editor.maxSize = .init(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.setFrameSize(.init(width: scroll.contentSize.width, height: max(editorHeight, editor.frame.height)))
        resize.frame = .init(x: scroll.frame.maxX - 14, y: scroll.frame.maxY - 14, width: 14, height: 14); y += editorHeight
        if errorHeight > 0 {
          y += 16; errorFrame = .init(x: title.frame.minX, y: y, width: inner, height: errorHeight)
          errorScroll.frame = errorFrame.insetBy(dx: 10, dy: 10)
          error.frame = .init(x: 0, y: 0, width: max(0, inner - 24), height: height(error, width: max(0, inner - 24)))
        } else { errorFrame = .zero }
      }
      let submitWidth = ceil((submit.title as NSString).size(withAttributes: [.font: submit.font ?? .systemFont(ofSize: 13)]).width) + 28 + (submit.loading ? 24 : 0)
      submit.frame = .init(x: panelFrame.maxX - 20 - submitWidth, y: panelFrame.maxY - 48, width: submitWidth, height: 28)
      cancel.frame = .init(x: submit.frame.minX - 70, y: submit.frame.minY, width: 62, height: 28)
      progress.frame = .init(x: submit.frame.minX + 8, y: submit.frame.minY + 6, width: 16, height: 16)
      needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
      NSColor.black.withAlphaComponent(0.3).setFill(); bounds.fill()
      NSGraphicsContext.saveGraphicsState()
      let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
      shadow.shadowBlurRadius = 24; shadow.shadowOffset = .init(width: 0, height: -8); shadow.set()
      let path = NSBezierPath(roundedRect: dialogFrame, xRadius: 20, yRadius: 20)
      preferences.resolvedColors["elevatedSecondary"].nativeColor.setFill(); path.fill(); NSGraphicsContext.restoreGraphicsState()
      preferences.resolvedColors["border"].nativeColor.setStroke(); path.lineWidth = 0.5; path.stroke()
      if mode == .review {
        let field = NSBezierPath(roundedRect: scroll.frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        preferences.resolvedColors["controlBackground"].nativeColor.setFill(); field.fill()
        preferences.resolvedColors[window?.firstResponder === editor ? "borderFocus" : "borderHeavy"].nativeColor.setStroke()
        field.lineWidth = 1; field.stroke()
        if !errorFrame.isEmpty { NSColor.systemRed.withAlphaComponent(0.08).setFill(); NSBezierPath(roundedRect: errorFrame, xRadius: 8, yRadius: 8).fill() }
      }
    }
  }

  @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: PullRequestDiscussionDialogPresenter
    var preferences = AppearancePreferences()
    let host = WindowDialogHost()
    private var lastDeleteError: String?
    private var updating = false
    private var undoObservers: [NSObjectProtocol] = []
    private weak var observedUndo: UndoManager?
    init(_ parent: PullRequestDiscussionDialogPresenter) {
      self.parent = parent; super.init()
      host.identity = { [weak self] in self?.mode?.identity }
      host.valid = { [weak self] in self?.parent.valid() == true }
      host.canDismiss = { [weak self] in self?.parent.state.busy == false }
      host.onDismiss = { [weak self] in self?.close() }
      host.key = { [weak self] event in self?.handleFormKey(event) == true }
      host.make = { [weak self] frame in
        guard let self, let mode = self.mode else { return WindowDialogSurface(frame: frame) }
        self.lastDeleteError = nil
        let form = Surface(frame: frame, mode: mode); form.owner = self; self.bind(form); self.configure(form); return form
      }
    }
    var mode: Mode? {
      if parent.state.showingReview { return .review }
      return parent.state.deleteTarget.map(Mode.delete)
    }
    private func owns(_ form: Surface) -> Bool { host.canAct() && host.surface === form && form.mode.identity == mode?.identity }
    private var canEditReview: Bool {
      parent.valid() && parent.writable && parent.state.snapshot?.canReview == true
        && parent.state.canEdit(.review, writable: parent.writable)
    }
    private func canSubmit(_ form: Surface) -> Bool {
      guard owns(form), parent.state.canWrite(parent.request, writable: parent.writable) else { return false }
      switch form.mode {
      case .review: return parent.state.snapshot?.canReview == true && !form.editor.hasMarkedText()
      case .delete(let comment): return parent.state.snapshot?.comment(comment.id)?.canDelete == true
      }
    }
    private func bind(_ form: Surface) {
      form.editor.delegate = self
      form.editor.available = { [weak self, weak form] in
        guard let self, let form else { return false }; return self.owns(form) && self.canEditReview
      }
      for (index, button) in form.decisions.enumerated() {
        button.available = { [weak self, weak form] in
          guard let self, let form else { return false }; return self.owns(form) && self.canEditReview
        }
        button.select = { [weak self, weak form] in if let form { self?.select(GitHubPRReviewDecision.allCases[index], in: form) } }
      }
      form.cancel.available = { [weak self, weak form] in
        guard let self, let form else { return false }; return self.owns(form) && !self.parent.state.busy
      }
      form.submit.available = { [weak self, weak form] in
        guard let self, let form else { return false }
        return self.canSubmit(form) || (self.owns(form) && !self.parent.state.busy && form.mode == .review && self.parent.state.uncertainOwner == .review)
      }
      form.cancel.activate = { [weak self, weak form] in
        guard let self, let form, self.owns(form) else { return }; self.host.dismiss()
      }
      form.submit.activate = { [weak self, weak form] in if let form { self?.submit(form) } }
      observeUndo(form)
    }
    private func observeUndo(_ form: Surface) {
      guard let manager = form.editor.undoManager, observedUndo !== manager else { return }
      undoObservers.forEach(NotificationCenter.default.removeObserver); undoObservers = []; observedUndo = manager
      for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
        undoObservers.append(NotificationCenter.default.addObserver(forName: name, object: manager, queue: .main) { [weak self, weak form] _ in
          MainActor.assumeIsolated { if let self, let form { self.textDidChange(.init(name: NSText.didChangeNotification, object: form.editor)) } }
        })
      }
    }
    func textDidBeginEditing(_ notification: Notification) {
      if let form = host.surface as? Surface, notification.object as AnyObject? === form.editor { observeUndo(form) }
    }

    func configure(_ form: Surface) {
      guard form.mode.identity == mode?.identity else { return }
      updating = true; defer { updating = false }
      form.preferences = preferences
      form.title.font = NSFont(descriptor: preferences.nativeFont(size: 20).fontDescriptor.addingAttributes(
        [.traits: [NSFontDescriptor.TraitKey.weight: NSFont.Weight.semibold.rawValue]]), size: 0)
      for label in [form.subtitle, form.decisionLabel, form.commentLabel, form.error] { label.font = preferences.nativeFont(size: 13) }
      form.title.textColor = preferences.resolvedColors["textForeground"].nativeColor
      form.subtitle.textColor = preferences.resolvedColors["textForegroundSecondary"].nativeColor
      for label in [form.decisionLabel, form.commentLabel] { label.textColor = preferences.resolvedColors["textForeground"].nativeColor }
      let busy = parent.state.busy
      for (index, radio) in form.decisions.enumerated() {
        radio.font = preferences.nativeFont(size: 13); radio.preferences = preferences
        radio.state = parent.state.reviewDecision == GitHubPRReviewDecision.allCases[index] ? .on : .off
        radio.isEnabled = canEditReview; radio.needsDisplay = true
      }
      if !form.editor.hasMarkedText(), form.editor.string != parent.state.reviewBody {
        let range = form.editor.selectedRange(), length = parent.state.reviewBody.utf16.count
        form.editor.string = parent.state.reviewBody
        form.editor.setSelectedRange(.init(location: min(range.location, length), length: min(range.length, max(0, length - range.location))))
      }
      form.editor.font = preferences.nativeFont(size: 13); form.editor.textColor = preferences.resolvedColors["textForeground"].nativeColor
      form.editor.placeholder = parent.state.reviewDecision == .approve ? "可选评论" : "添加评论…"
      form.editor.isEditable = canEditReview; form.editor.isSelectable = canEditReview
      form.error.stringValue = parent.state.message(for: .review) ?? ""; form.error.textColor = .systemRed
      form.errorScroll.isHidden = form.mode != .review || parent.state.message(for: .review) == nil
      form.cancel.isEnabled = !busy
      form.submit.title = form.mode == .review && parent.state.uncertainOwner == .review ? "重新读取操作结果" : form.mode == .review ? "提交审查" : "删除评论"
      let eligible: Bool
      switch form.mode {
      case .review: eligible = parent.state.snapshot?.canReview == true && parent.state.reviewAction != nil
      case .delete(let target): eligible = parent.state.snapshot?.comment(target.id)?.canDelete == true
      }
      form.submit.isEnabled = !busy && ((eligible && parent.state.canWrite(parent.request, writable: parent.writable))
        || (form.mode == .review && parent.state.uncertainOwner == .review))
      form.submit.loading = busy
      for button in [form.cancel, form.submit] { button.font = preferences.nativeFont(size: 13); button.preferences = preferences; button.needsDisplay = true }
      form.progress.appearance = NSAppearance(named: preferences.theme == "dark" ? .aqua : .darkAqua)
      if busy { form.progress.startAnimation(nil) } else { form.progress.stopAnimation(nil) }
      let children: [NSView] = form.mode == .review
        ? [form.subtitle, form.decisionLabel] + form.decisions + [form.commentLabel, form.scroll, form.errorScroll, form.cancel, form.submit]
        : [form.subtitle, form.cancel, form.submit]
      form.setAccessibilityChildren(children.filter { !$0.isHidden }); form.needsLayout = true; form.needsDisplay = true
      reportDeleteFailure(form)
    }
    func select(_ decision: GitHubPRReviewDecision, in form: Surface) {
      guard owns(form), canEditReview else { return }
      parent.state.reviewDecision = decision; parent.state.clearError(.review); configure(form)
    }
    func textDidChange(_ notification: Notification) {
      guard !updating, let form = host.surface as? Surface, notification.object as AnyObject? === form.editor,
        owns(form), canEditReview, !form.editor.hasMarkedText() else { return }
      observeUndo(form)
      parent.state.reviewBody = form.editor.string; parent.state.clearError(.review); configure(form)
    }
    func submit(_ form: Surface) {
      if owns(form), form.mode == .review, !parent.state.busy, parent.state.uncertainOwner == .review { parent.confirmReview(); return }
      guard canSubmit(form) else { return }
      switch form.mode {
      case .review:
        guard parent.state.validateReviewSubmission() else { configure(form); return }; parent.submitReview()
      case .delete(let target): parent.deleteComment(target)
      }
    }
    private func close() {
      switch mode {
      case .review: parent.state.closeReview()
      case .delete(let target): parent.state.deleteTarget = nil; parent.state.clearError(.delete(target.id))
      case nil: break
      }
    }
    @discardableResult func handleFormKey(_ event: NSEvent) -> Bool {
      guard let form = host.surface as? Surface, owns(form) else { return false }
      let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
      let responder = host.window?.firstResponder
      if responder === form.editor {
        if !form.editor.hasMarkedText(), [36, 76].contains(event.keyCode), flags.contains(.command) || flags.contains(.control) {
          if !event.isARepeat { submit(form) }; return true
        }
        return false
      }
      if let radio = responder as? DecisionControl, let index = form.decisions.firstIndex(of: radio) {
        if flags.isEmpty, [123, 124, 125, 126].contains(event.keyCode), canEditReview {
          let next = (index + ([123, 126].contains(event.keyCode) ? -1 : 1) + form.decisions.count) % form.decisions.count
          select(GitHubPRReviewDecision.allCases[next], in: form); host.window?.makeFirstResponder(form.decisions[next]); return true
        }
        if flags.isEmpty, [36, 76].contains(event.keyCode) { if !event.isARepeat { submit(form) }; return true }
        if flags.isEmpty, event.keyCode == 49 { if !event.isARepeat { _ = radio.accessibilityPerformPress() }; return true }
      }
      if flags.isEmpty, [36, 49, 76].contains(event.keyCode), let button = responder as? ActionButton {
        if !event.isARepeat { _ = button.accessibilityPerformPress() }; return true
      }
      return false
    }
    private func reportDeleteFailure(_ form: Surface) {
      guard case .delete(let target) = form.mode else { return }
      let error = parent.state.message(for: .delete(target.id))
      guard error != lastDeleteError else { return }; lastDeleteError = error
      guard let error else { return }
      DispatchQueue.main.async { [weak self, weak form] in
        guard let self, let form, self.owns(form), self.parent.state.message(for: .delete(target.id)) == error else { return }
        self.parent.reportDeleteError(error)
      }
    }
    func stop() { host.stop(); undoObservers.forEach(NotificationCenter.default.removeObserver); undoObservers = [] }
    deinit { undoObservers.forEach(NotificationCenter.default.removeObserver) }
  }
}
