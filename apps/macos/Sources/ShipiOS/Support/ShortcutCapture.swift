import AppKit
import SwiftUI

/// A focusable read-only recorder. Only its own first-responder events are
/// captured; clicking another row or control immediately ends command capture.
struct ShortcutCapture: NSViewRepresentable {
  let text: String
  let accessibilityLabel: String
  let receive: (NSEvent) -> Void
  let activityChanged: (Bool) -> Void
  let onBlur: () -> Void

  func makeNSView(context: Context) -> Field {
    let view = Field()
    configure(view)
    view.install()
    return view
  }
  func updateNSView(_ view: Field, context: Context) { configure(view) }
  private func configure(_ view: Field) {
    view.label.stringValue = text
    view.setAccessibilityLabel(accessibilityLabel)
    view.setAccessibilityValue(text)
    view.receive = receive
    view.activityChanged = activityChanged
    view.onBlur = onBlur
  }
  static func dismantleNSView(_ view: Field, coordinator: ()) { view.stop() }

  final class Field: NSView {
    let label = NSTextField(labelWithString: "")
    var receive: ((NSEvent) -> Void)?
    var activityChanged: ((Bool) -> Void)?
    var onBlur: (() -> Void)?
    private var monitor: Any?
    private var windowObserver: NSObjectProtocol?
    private var active = false
    private var stopped = false
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 144, height: 28) }

    init() {
      super.init(frame: .zero)
      wantsLayer = true
      label.font = .systemFont(ofSize: 13)
      label.lineBreakMode = .byTruncatingTail
      label.translatesAutoresizingMaskIntoConstraints = false
      addSubview(label)
      NSLayoutConstraint.activate([
        label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
        label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        label.centerYAnchor.constraint(equalTo: centerYAnchor)
      ])
      setAccessibilityElement(true)
      setAccessibilityRole(.textField)
      updateStyle()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
      windowObserver = nil
      if let window {
        windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
          object: window, queue: .main) { [weak self] _ in
            guard let self, self.active, self.window?.firstResponder === self else { return }
            self.window?.makeFirstResponder(nil)
          }
      }
      DispatchQueue.main.async { [weak self] in
        guard let self, !self.stopped, let window = self.window, window.isKeyWindow,
          window.attachedSheet == nil, NSApp.modalWindow == nil else { return }
        window.makeFirstResponder(self)
      }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateStyle() }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func becomeFirstResponder() -> Bool {
      guard !stopped else { return false }
      if !active { active = true; activityChanged?(true) }
      updateStyle()
      return true
    }
    override func resignFirstResponder() -> Bool {
      if active { active = false; activityChanged?(false); onBlur?() }
      updateStyle()
      return true
    }
    func install() {
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self, !self.stopped, let window = self.window, window.isKeyWindow,
          event.window === window, window.firstResponder === self,
          window.attachedSheet == nil, NSApp.modalWindow == nil else { return event }
        self.receive?(event)
        return nil
      }
    }
    override func keyDown(with event: NSEvent) { receive?(event) }
    func stop() {
      stopped = true
      if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
      if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }; windowObserver = nil
      onBlur = nil
      if window?.firstResponder === self { window?.makeFirstResponder(nil) }
      if active { active = false; activityChanged?(false) }
      receive = nil; activityChanged = nil; onBlur = nil
    }
    private func updateStyle() {
      effectiveAppearance.performAsCurrentDrawingAppearance {
        layer?.cornerRadius = 6
        layer?.borderWidth = active ? 2 : 1
        layer?.borderColor = (active ? NSColor.keyboardFocusIndicatorColor : NSColor.separatorColor).cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
      }
    }
    deinit {
      if let monitor { NSEvent.removeMonitor(monitor) }
      if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
    }
  }
}
