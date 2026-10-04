import AppKit
import SwiftTerm
import SwiftUI

/// Read-only output content, not a local shell or an execution-details modal.
struct BackgroundTerminalOutputView: View {
  let document: CodexBackgroundTerminalDocument?
  var focused = false
  var canFocus: () -> Bool = { false }
  var openLink: (URL) -> Void = { _ in }
  var body: some View {
    Group {
      if let document {
        if document.output.isEmpty {
          Text("暂无输出").appFont(.caption, design: .monospaced).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(16)
        } else {
          BackgroundTerminalOutputHost(output: document.output, focused: focused,
            canFocus: canFocus, openLink: openLink)
            .padding(.vertical, 12).padding(.leading, 12).id(document.id)
        }
      } else {
        ContentUnavailableView("后台终端输出不可用", systemImage: "terminal")
      }
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

final class BackgroundOutputTerminalView: TerminalView {
  weak var outputCoordinator: BackgroundTerminalOutputHost.Coordinator?
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    outputCoordinator?.scheduleFocus()
  }
  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = NSMenu(title: "后台终端输出")
    for (title, action) in [("复制", #selector(copy(_:))), ("全选", #selector(selectAll(_:)))] {
      let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
      item.target = self; item.isEnabled = validateUserInterfaceItem(item)
    }
    return menu
  }
}

struct BackgroundTerminalOutputHost: NSViewRepresentable {
  @Environment(\.appAppearance) private var appearance
  let output: String
  var focused = false
  var canFocus: () -> Bool = { false }
  var openLink: (URL) -> Void = { _ in }

  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> BackgroundOutputTerminalView {
    let view = BackgroundOutputTerminalView(frame: .zero, font: nil,
      options: TerminalOptions(convertEol: true, scrollback: 4096))
    view.terminalDelegate = context.coordinator
    view.outputCoordinator = context.coordinator
    view.setAccessibilityLabel("后台终端输出")
    return view
  }
  func updateNSView(_ view: BackgroundOutputTerminalView, context: Context) {
    // nativeFont applies the user's codeSize to the 12-point baseline.
    view.font = appearance.nativeFont(size: 12, code: true)
    view.nativeBackgroundColor = appearance.backgroundHex.flatMap(AppearancePreferences.color).map(NSColor.init)
      ?? .textBackgroundColor
    view.nativeForegroundColor = appearance.foregroundHex.flatMap(AppearancePreferences.color).map(NSColor.init)
      ?? .textColor
    context.coordinator.update(view, output: output)
    context.coordinator.updateInteraction(view, focused: focused, canFocus: canFocus, openLink: openLink)
  }
  static func dismantleNSView(_ view: BackgroundOutputTerminalView, coordinator: Coordinator) {
    view.terminalDelegate = nil
    view.outputCoordinator = nil
    coordinator.detach()
  }
  final class Coordinator: NSObject, TerminalViewDelegate {
    private var rendered = Data()
    private weak var view: BackgroundOutputTerminalView?
    private var focusWanted = false
    private(set) var focusHandled = false
    private var canFocus: () -> Bool = { false }
    private var openLink: (URL) -> Void = { _ in }
    func updateInteraction(_ view: BackgroundOutputTerminalView, focused: Bool,
      canFocus: @escaping () -> Bool, openLink: @escaping (URL) -> Void) {
      self.view = view; self.canFocus = canFocus; self.openLink = openLink
      view.outputCoordinator = self
      focusWanted = focused
      if !focused { focusHandled = false }
      scheduleFocus()
    }
    func scheduleFocus() {
      DispatchQueue.main.async { [weak self] in
        guard let self, focusWanted, !focusHandled, canFocus(), let view,
          view.outputCoordinator === self, let window = view.window, window.isKeyWindow,
          window.attachedSheet == nil, NSApp.modalWindow == nil else { return }
        focusHandled = window.makeFirstResponder(view)
      }
    }
    func detach() {
      if view?.outputCoordinator === self { view?.outputCoordinator = nil }
      view = nil; focusWanted = false; canFocus = { false }; openLink = { _ in }
    }
    func update(_ view: TerminalView, output: String) {
      let bytes = Data(output.utf8)
      guard bytes != rendered else { return }
      if bytes.starts(with: rendered) {
        view.feed(byteArray: Array(bytes.dropFirst(rendered.count))[...])
      } else {
        // Cancel a pending control sequence before replacing the entire
        // document. Resetting the buffer alone leaves the parser in that state.
        view.feed(text: "\u{18}")
        view.getTerminal().resetToInitialState(); view.clearScrollback()
        view.feed(byteArray: Array(bytes)[...])
      }
      rendered = bytes
      // Do not feed another escape into a possibly incomplete output sequence.
      view.getTerminal().hideCursor()
    }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) {} // No process input exists.
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
      guard let url = URL(string: link) else { return }
      openLink(url)
    }
    func bell(source: TerminalView) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
  }
}
