import AppKit
import SwiftUI

private struct MessageTextIsSecondaryKey: EnvironmentKey {
  static let defaultValue = false
}
extension EnvironmentValues {
  var messageTextIsSecondary: Bool {
    get { self[MessageTextIsSecondaryKey.self] }
    set { self[MessageTextIsSecondaryKey.self] = newValue }
  }
}

/// macOS 14 has no TextRenderer. Keep its linked paragraphs selectable using
/// AppKit's text layout and the same actions as the newer SwiftUI path.
struct LegacyMessageLinkText: NSViewRepresentable {
  let text: AttributedString
  let fontSize: CGFloat
  let weight: NSFont.Weight
  let actions: MessageLinkActions
  @Environment(\.appAppearance) private var appearance
  @Environment(\.openURL) private var openURL
  @Environment(\.lineSpacing) private var lineSpacing
  @Environment(\.multilineTextAlignment) private var alignment
  @Environment(\.messageTextIsSecondary) private var secondary

  func makeNSView(context: Context) -> TextView {
    let view = TextView()
    view.isEditable = false
    view.isSelectable = true
    view.isRichText = true
    view.drawsBackground = false
    view.textContainerInset = .zero
    view.textContainer?.lineFragmentPadding = 0
    view.textContainer?.widthTracksTextView = true
    view.isVerticallyResizable = true
    view.isHorizontallyResizable = false
    view.minSize = .zero
    view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    view.linkTextAttributes = [:]
    view.delegate = view
    return view
  }

  func updateNSView(_ view: TextView, context: Context) {
    let native = Self.attributedText(text, appearance: appearance, size: fontSize, weight: weight,
      lineSpacing: lineSpacing, alignment: alignment, secondary: secondary)
    view.actions = actions
    view.openLink = { url in openURL(url) }
    view.update(native)
    view.setAccessibilityCustomActions(MessageAccessibleLink.links(in: text).flatMap { link in
      MessageLinkAction.allCases.map { action in
        NSAccessibilityCustomAction(name: link.title(for: action)) {
          actions.perform(link.url, action)
          return true
        }
      }
    })
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: TextView, context: Context) -> CGSize? {
    if proposal.width == 0 { return .zero }
    let width = proposal.width.flatMap { $0.isFinite ? max(1, $0) : nil } ?? 10000
    // SwiftUI also asks for the ideal size after measuring a finite proposal.
    // Do not leave the live text container at that probe's unconstrained width.
    guard let content = nsView.textStorage else { return nil }
    let storage = NSTextStorage(attributedString: content)
    let manager = NSLayoutManager()
    let container = NSTextContainer(containerSize: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    storage.addLayoutManager(manager)
    manager.addTextContainer(container)
    manager.ensureLayout(for: container)
    let used = manager.usedRect(for: container)
    return CGSize(width: proposal.width == nil ? ceil(used.width) : width, height: ceil(used.height))
  }

  static func attributedText(_ text: AttributedString, appearance: AppearancePreferences,
    size: CGFloat, weight: NSFont.Weight = .regular, lineSpacing: CGFloat = 5,
    alignment: TextAlignment = .leading, secondary: Bool = false) -> NSAttributedString {
    let result = NSMutableAttributedString(string: "")
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = lineSpacing
    paragraph.alignment = alignment == .center ? .center : alignment == .trailing ? .right : .natural
    let base = appearance.nativeFont(size: size)
    for run in text.runs {
      let intent = run.inlinePresentationIntent ?? []
      var font = intent.contains(.code) ? NSFont.monospacedSystemFont(ofSize: base.pointSize, weight: weight)
        : NSFont(descriptor: base.fontDescriptor.addingAttributes([
          .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue]]), size: base.pointSize) ?? base
      if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
      if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
      var attributes: [NSAttributedString.Key: Any] = [
        .font: font, .paragraphStyle: paragraph,
        .foregroundColor: NSColor(run.link == nil ? appearance.foregroundColor : appearance.accentColor),
      ]
      if secondary && run.link == nil { attributes[.foregroundColor] = NSColor.secondaryLabelColor }
      if let color = run.swiftUI.foregroundColor { attributes[.foregroundColor] = NSColor(color) }
      if let color = run.swiftUI.backgroundColor { attributes[.backgroundColor] = NSColor(color) }
      if let url = run.link { attributes[.link] = url; attributes[.toolTip] = url.absoluteString }
      if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
      result.append(NSAttributedString(string: String(text[run.range].characters), attributes: attributes))
    }
    return result
  }

  final class TextView: NSTextView, NSTextViewDelegate {
    var actions: MessageLinkActions?
    var openLink: ((URL) -> Void)?
    private var pressed: (url: URL, point: NSPoint, activate: (URL, WebLinkClick) -> Void)?
    private var trackingLinkGesture = false

    func update(_ content: NSAttributedString) {
      guard textStorage?.isEqual(to: content) != true else { return }
      let selected = selectedRange()
      textStorage?.setAttributedString(content)
      let start = min(selected.location, content.length)
      setSelectedRange(NSRange(location: start, length: min(selected.length, content.length - start)))
      invalidateIntrinsicContentSize()
    }
    func link(at point: NSPoint) -> URL? {
      guard let manager = layoutManager, let container = textContainer else { return nil }
      manager.ensureLayout(for: container)
      guard manager.numberOfGlyphs > 0 else { return nil }
      let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
      let glyph = manager.glyphIndex(for: local, in: container)
      guard glyph < manager.numberOfGlyphs,
        manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(local) else { return nil }
      return link(atCharacter: manager.characterIndexForGlyph(at: glyph))
    }
    private func link(atCharacter index: Int) -> URL? {
      guard let storage = textStorage, index >= 0, index < storage.length else { return nil }
      return storage.attribute(.link, at: index, effectiveRange: nil) as? URL
    }
    func linkMenu(_ url: URL) -> NSMenu? {
      guard let actions, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
      return MessageLinkMenu.make(url: url, actions: actions)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
      if let url = link(at: convert(event.locationInWindow, from: nil)) {
        // Non-web links still route through the app's file validation on activation.
        return linkMenu(url)
      }
      return super.menu(for: event)
    }
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
      guard let url = link as? URL else { return false }
      openLink?(url)
      return true
    }
    override func mouseDown(with event: NSEvent) {
      if event.modifierFlags.contains(.control) { super.mouseDown(with: event); return }
      if !event.modifierFlags.intersection([.command, .option]).isEmpty, begin(event) { return }
      super.mouseDown(with: event)
    }
    override func mouseUp(with event: NSEvent) {
      if trackingLinkGesture { finish(event) } else { super.mouseUp(with: event) }
    }
    override func mouseDragged(with event: NSEvent) {
      if let pressed {
        let point = convert(event.locationInWindow, from: nil)
        if hypot(point.x - pressed.point.x, point.y - pressed.point.y) > 4 { self.pressed = nil }
      } else if !trackingLinkGesture { super.mouseDragged(with: event) }
    }
    override func otherMouseDown(with event: NSEvent) {
      if event.buttonNumber == 2, begin(event) { return }
      super.otherMouseDown(with: event)
    }
    override func otherMouseUp(with event: NSEvent) {
      if trackingLinkGesture { finish(event) } else { super.otherMouseUp(with: event) }
    }
    override func otherMouseDragged(with event: NSEvent) { mouseDragged(with: event) }
    private func begin(_ event: NSEvent) -> Bool {
      let point = convert(event.locationInWindow, from: nil)
      guard let url = link(at: point), linkMenu(url) != nil, let actions else { return false }
      pressed = (url, point, actions.activate)
      trackingLinkGesture = true
      return true
    }
    private func finish(_ event: NSEvent) {
      defer { pressed = nil; trackingLinkGesture = false }
      guard let pressed, link(at: convert(event.locationInWindow, from: nil)) == pressed.url,
        let click = WebLinkClick(event: event) else { return }
      pressed.activate(pressed.url, click)
    }
    override func accessibilityPerformShowMenu() -> Bool {
      guard let url = link(atCharacter: selectedRange().location), let menu = linkMenu(url) else { return false }
      return menu.popUp(positioning: nil, at: .zero, in: self)
    }
  }
}
