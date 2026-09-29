import SwiftUI

enum CodeSyntaxText {
  static func text(_ line: ReviewDiffLine, tokens: [CodeSyntaxToken]?, marker: DiffMarkerStyle, dark: Bool) -> Text {
    guard let tokens, !tokens.isEmpty else { return Text(line.displayText(markerStyle: marker)) }
    let prefix = marker == .symbols || line.kind == .context ? String(line.text.prefix(1)) : ""
    return tokens.reduce(Text(prefix)) { result, token in
      let style = dark ? token.dark : token.light
      var text = Text(token.content)
      if let color = style.color.flatMap(color) { text = text.foregroundColor(color) }
      if style.fontStyle & 1 != 0 { text = text.italic() }
      if style.fontStyle & 2 != 0 { text = text.bold() }
      if style.fontStyle & 4 != 0 { text = text.underline() }
      return result + text
    }
  }
  private static func color(_ value: String) -> Color? {
    guard let rgb = UInt64(value.dropFirst(), radix: 16) else { return nil }
    let alpha = value.count == 9 ? Double(rgb & 255) / 255 : 1
    let components = value.count == 9 ? rgb >> 8 : rgb
    return Color(.sRGB, red: Double((components >> 16) & 255) / 255,
      green: Double((components >> 8) & 255) / 255, blue: Double(components & 255) / 255, opacity: alpha)
  }
}
