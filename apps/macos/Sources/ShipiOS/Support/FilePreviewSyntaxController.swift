import AppKit
import SwiftUI

/// Owns only one native preview's pending calculation. Recoloring never assigns
/// its string, changes its selection or requests focus.
@MainActor final class FilePreviewSyntaxController {
  private let service: any CodeSyntaxHighlighting
  private var task: Task<Void, Never>?
  private var generation = UUID()
  private var path: String?
  private var source: String?
  private var input: CodeSyntaxInput?
  private var result: CodeSyntaxResult?
  private var appearance = AppearancePreferences()
  private var paintedAppearance: AppearancePreferences?
  private var paintedDark: Bool?
  private(set) var error: String?
  init(service: (any CodeSyntaxHighlighting)? = nil) { self.service = service ?? CodeSyntaxService.shared }

  func update(_ text: NSTextView, path: String?, source: String, ready: Bool, appearance: AppearancePreferences) {
    self.appearance = appearance
    guard ready, let path else {
      stop(); self.path = nil; self.source = nil; input = nil; result = nil
      paint(text); return
    }
    let sameSource = self.path == path && self.source?.utf8.elementsEqual(source.utf8) == true
    if sameSource, input?.themes == appearance.codeThemes {
      paint(text); return
    }
    stop(); self.path = path; self.source = source
    let input = CodeSyntaxInput(path: path, source: source, themes: appearance.codeThemes)
    self.input = input
    if !sameSource { result = nil }
    error = nil; paintedAppearance = nil
    paint(text)
    let token = generation, service = service
    task = Task { [weak self, weak text] in
      do {
        let result = try await service.highlight(input)
        try result.validate(input); try Task.checkCancellation()
        guard let self, let text, self.generation == token,
          text.string.utf8.elementsEqual(source.utf8) else { return }
        self.result = result; self.paintedAppearance = nil; self.paint(text)
      } catch {
        guard let self, self.generation == token, !Task.isCancelled else { return }
        self.error = error.localizedDescription
      }
    }
  }
  func stop() { generation = UUID(); task?.cancel(); task = nil; paintedAppearance = nil }
  deinit { task?.cancel() }

  private func paint(_ text: NSTextView) {
    let dark = appearance.isDark
    guard paintedAppearance != appearance || paintedDark != dark else { return }
    paintedAppearance = appearance; paintedDark = dark
    let font = appearance.nativeFont(size: 12, code: true)
    let color = NSColor(appearance.codeForegroundColor)
    text.drawsBackground = true; text.backgroundColor = NSColor(appearance.codeBackgroundColor)
    guard let storage = text.textStorage else { return }
    let selection = text.selectedRanges, origin = text.enclosingScrollView?.contentView.bounds.origin
    storage.beginEditing()
    storage.setAttributes([.font: font, .foregroundColor: color], range: NSRange(location: 0, length: storage.length))
    if let input, let result, text.string.utf8.elementsEqual(source?.utf8 ?? "".utf8) {
      var offset = 0
      for (line, row) in zip(input.lines, result.right) {
        for token in row.tokens {
          let length = (token.content as NSString).length
          let style = dark ? token.dark : token.light
          var tokenFont = font
          if style.fontStyle & 1 != 0 { tokenFont = NSFontManager.shared.convert(tokenFont, toHaveTrait: .italicFontMask) }
          if style.fontStyle & 2 != 0 { tokenFont = NSFontManager.shared.convert(tokenFont, toHaveTrait: .boldFontMask) }
          var attributes: [NSAttributedString.Key: Any] = [.font: tokenFont]
          if let value = style.color.flatMap(Self.color) { attributes[.foregroundColor] = value }
          if style.fontStyle & 4 != 0 { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
          storage.addAttributes(attributes, range: NSRange(location: offset, length: length))
          offset += length
        }
        offset += (line.id == input.lines.last?.id ? 0 : 1)
      }
    }
    storage.endEditing()
    text.selectedRanges = selection
    if let scroll = text.enclosingScrollView, let origin {
      scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView)
    }
  }
  private static func color(_ value: String) -> NSColor? {
    guard let rgb = UInt64(value.dropFirst(), radix: 16) else { return nil }
    let alpha = value.count == 9 ? CGFloat(rgb & 255) / 255 : 1
    let components = value.count == 9 ? rgb >> 8 : rgb
    return NSColor(srgbRed: CGFloat((components >> 16) & 255) / 255,
      green: CGFloat((components >> 8) & 255) / 255, blue: CGFloat(components & 255) / 255, alpha: alpha)
  }
}
