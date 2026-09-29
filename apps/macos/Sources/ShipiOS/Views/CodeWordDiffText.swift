import SwiftUI

struct CodeWordAttribute: TextAttribute { let group: Int }

/// Keep one native Text for selection, wrapping and shaping. Backgrounds are
/// drawn behind its actual glyph runs rather than replacing code with HTML.
struct CodeWordDiffText: View {
  let line: ReviewDiffLine
  let tokens: [CodeSyntaxToken]?
  let changes: [CodeWordRange]
  let marker: DiffMarkerStyle
  let dark: Bool
  var body: some View {
    if #available(macOS 15, *) {
      CodeSyntaxText.text(line, tokens: tokens, marker: marker, dark: dark, changes: changes)
        .textRenderer(CodeWordDiffRenderer(kind: line.kind, dark: dark))
    } else {
      CodeSyntaxText.text(line, tokens: tokens, marker: marker, dark: dark)
    }
  }
  static var supported: Bool {
    if #available(macOS 15, *) { return true }; return false
  }
}

@available(macOS 15, *)
struct CodeWordDiffRenderer: TextRenderer {
  let kind: ReviewDiffLine.Kind
  let dark: Bool
  var color: Color {
    let hex = kind == .deletion ? (dark ? 0xff6762 : 0xff2e3f) : (dark ? 0x5ecc71 : 0x0dbe4e)
    return Color(.sRGB, red: Double((hex >> 16) & 255) / 255,
      green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: dark ? 0.2 : 0.15)
  }
  func draw(layout: Text.Layout, in context: inout GraphicsContext) {
    for line in layout {
      // Adjacent grammar runs in one word range share a single rounded shape.
      // Each wrapped line starts a new rectangle, like box-decoration-break.
      var group: Int?, rectangle: CGRect?
      func fill() {
        if let rectangle {
          context.fill(RoundedRectangle(cornerRadius: 3).path(in: rectangle), with: .color(color))
        }
      }
      for run in line {
        if let attribute = run[CodeWordAttribute.self] {
          if group == attribute.group, let previous = rectangle {
            rectangle = previous.union(run.typographicBounds.rect)
          } else {
            fill(); group = attribute.group; rectangle = run.typographicBounds.rect
          }
        } else { fill(); group = nil; rectangle = nil }
      }
      fill()
      for run in line { context.draw(run) }
    }
  }
}

struct CodeWordDiffMenu: View {
  @Bindable var store: WorkspaceStore
  var body: some View {
    Button(store.reviewWordDiffs ? "关闭词级差异" : "开启词级差异") { store.reviewWordDiffs.toggle() }
      .disabled(!store.libraryLoaded || !CodeWordDiffText.supported)
      .help(CodeWordDiffText.supported ? "突出显示修改行中的词语差异" : "词级差异显示需要 macOS 15 或更新版本")
      .accessibilityIdentifier("review-word-diffs-toggle")
  }
}
