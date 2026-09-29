import SwiftUI

enum CodeSyntaxText {
  struct Segment: Equatable {
    let content: String
    let style: CodeSyntaxToken.Style
    let group: Int?
  }
  static func segments(_ tokens: [CodeSyntaxToken], changes: [CodeWordRange], dark: Bool) -> [Segment] {
    if changes.isEmpty { return tokens.map { .init(content: $0.content, style: dark ? $0.dark : $0.light, group: nil) } }
    let source = tokens.map(\.content).joined()
    let changes = CodeWordRange.valid(changes, in: source) ? changes : []
    var offset = 0, result: [Segment] = [], changeIndex = 0
    for token in tokens {
      let content = token.content as NSString, end = offset + content.length
      var cursor = offset
      while cursor < end {
        while changeIndex < changes.count && changes[changeIndex].end <= cursor { changeIndex += 1 }
        let range = changeIndex < changes.count ? changes[changeIndex] : nil
        let inside = range.map { $0.location <= cursor } ?? false
        let boundary = min(end, range.map { inside ? $0.end : $0.location } ?? end)
        result.append(.init(content: content.substring(with: NSRange(location: cursor - offset, length: boundary - cursor)),
          style: dark ? token.dark : token.light, group: inside ? changeIndex : nil))
        cursor = boundary
      }
      offset = end
    }
    return result
  }
  static func text(_ line: ReviewDiffLine, tokens: [CodeSyntaxToken]?, marker: DiffMarkerStyle, dark: Bool,
    changes: [CodeWordRange] = []) -> Text {
    guard let tokens, !tokens.isEmpty else { return Text(line.displayText(markerStyle: marker)) }
    let prefix = marker == .symbols || line.kind == .context ? String(line.text.prefix(1)) : ""
    return segments(tokens, changes: changes, dark: dark).reduce(Text(prefix)) { result, segment in
      let style = segment.style
      var text = Text(segment.content)
      if let color = style.color.flatMap(color) { text = text.foregroundColor(color) }
      if style.fontStyle & 1 != 0 { text = text.italic() }
      if style.fontStyle & 2 != 0 { text = text.bold() }
      if style.fontStyle & 4 != 0 { text = text.underline() }
      if let group = segment.group { text = text.customAttribute(CodeWordAttribute(group: group)) }
      return result + text
    }
  }
  static func color(_ value: String) -> Color? {
    guard let rgb = UInt64(value.dropFirst(), radix: 16) else { return nil }
    let alpha = value.count == 9 ? Double(rgb & 255) / 255 : 1
    let components = value.count == 9 ? rgb >> 8 : rgb
    return Color(.sRGB, red: Double((components >> 16) & 255) / 255,
      green: Double((components >> 8) & 255) / 255, blue: Double(components & 255) / 255, opacity: alpha)
  }
}
