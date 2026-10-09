import AppKit
import SwiftUI

/// Independent native geometry for the workspace toolbar's display states.
struct WorkspaceLayoutToolbarArtwork: Equatable {
  enum Glyph: Equatable { case rectangle, columns, enterFull, exitFull }
  let glyph: Glyph
  var count: Int?
  var pressed: Bool?
  var countLabel: String? { count.flatMap { $0 > 0 ? ($0 > 9 ? "9+" : String($0)) : nil } }
  var countFontSize: CGFloat { (count ?? 0) > 9 ? 6 : 8 }

  func draw(in bounds: NSRect, appearance: AppearancePreferences, hovered: Bool, enabled: Bool, focused: Bool) {
    let roles = appearance.resolvedColors
    let background = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
    if pressed == true || hovered && enabled {
      roles[hovered && enabled ? "buttonSecondaryBackgroundHover" : "buttonSecondaryBackground"].nativeColor.setFill()
      background.fill()
    }
    let foreground = roles["textForeground"].opacity(enabled ? 1 : 0.4).nativeColor
    NSGraphicsContext.saveGraphicsState()
    let nativeTransform = NSAffineTransform()
    nativeTransform.translateX(by: bounds.midX - 8, yBy: bounds.midY - 8)
    nativeTransform.concat()
    foreground.setStroke()
    let path = NSBezierPath(); path.lineWidth = 1.05; path.lineCapStyle = .round; path.lineJoinStyle = .round
    switch glyph {
    case .rectangle, .columns:
      path.appendRoundedRect(.init(x: 1.5, y: 2.2, width: 13, height: 11.6), xRadius: 1.9, yRadius: 1.9)
      if glyph == .columns { path.move(to: .init(x: 8, y: 2.2)); path.line(to: .init(x: 8, y: 13.8)) }
      path.stroke()
      if glyph == .rectangle {
        if let countLabel {
          let text = NSAttributedString(string: countLabel, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: countFontSize, weight: .semibold), .foregroundColor: foreground])
          text.draw(at: .init(x: 8 - text.size().width / 2, y: 8 - text.size().height / 2))
        } else if count == 0 {
          let plus = NSBezierPath(); plus.lineWidth = 0.8; plus.lineCapStyle = .round
          plus.move(to: .init(x: 4.6, y: 8)); plus.line(to: .init(x: 11.4, y: 8))
          plus.move(to: .init(x: 8, y: 4.6)); plus.line(to: .init(x: 8, y: 11.4)); plus.stroke()
        }
      }
    case .enterFull:
      path.move(to: .init(x: 9.5, y: 13)); path.line(to: .init(x: 13, y: 13)); path.line(to: .init(x: 13, y: 9.5))
      path.move(to: .init(x: 3, y: 6.5)); path.line(to: .init(x: 3, y: 3)); path.line(to: .init(x: 6.5, y: 3)); path.stroke()
    case .exitFull:
      path.move(to: .init(x: 13, y: 9.5)); path.line(to: .init(x: 9.5, y: 9.5)); path.line(to: .init(x: 9.5, y: 13))
      path.move(to: .init(x: 3, y: 6.5)); path.line(to: .init(x: 6.5, y: 6.5)); path.line(to: .init(x: 6.5, y: 3)); path.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    if focused && enabled { roles["borderFocus"].nativeColor.setStroke(); background.lineWidth = 2; background.stroke() }
  }
}

struct WorkspaceFullViewButton: View {
  let menu: WorkspaceLayoutMenu
  let shortcut: String
  let available: () -> Bool
  let perform: () -> Void
  var body: some View {
    AppearanceActionButton(title: "", label: menu.fullViewLabel,
      layoutArtwork: .init(glyph: menu.fullViewVisible ? .exitFull : .enterFull, pressed: menu.fullViewVisible),
      available: available) { _ in perform() }
      .help(menu.fullViewLabel + " " + shortcut)
      .accessibilityLabel(menu.fullViewLabel)
  }
}
