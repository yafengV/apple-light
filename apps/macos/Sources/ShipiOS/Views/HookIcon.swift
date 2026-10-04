import SwiftUI

/// The reference's 18-point Hooks glyph, drawn as scalable native geometry.
struct HookIcon: View {
  var body: some View {
    Canvas { context, size in
      let scale = min(size.width, size.height) / 18
      context.scaleBy(x: scale, y: scale)
      var path = Path()
      path.addEllipse(in: CGRect(x: 7.12305, y: 3, width: 3.75, height: 3.75))
      path.move(to: .init(x: 9, y: 6.75)); path.addLine(to: .init(x: 9, y: 12))
      path.addCurve(to: .init(x: 12, y: 15), control1: .init(x: 9, y: 13.6569), control2: .init(x: 10.3431, y: 15))
      path.addCurve(to: .init(x: 15, y: 12), control1: .init(x: 13.6569, y: 15), control2: .init(x: 15, y: 13.6569))
      path.addLine(to: .init(x: 15, y: 9.75)); path.addLine(to: .init(x: 13.5, y: 11.25))
      path.move(to: .init(x: 9, y: 6.75)); path.addLine(to: .init(x: 9, y: 12))
      path.addCurve(to: .init(x: 6, y: 15), control1: .init(x: 9, y: 13.6569), control2: .init(x: 7.65685, y: 15))
      path.addCurve(to: .init(x: 3, y: 12), control1: .init(x: 4.34315, y: 15), control2: .init(x: 3, y: 13.6569))
      path.addLine(to: .init(x: 3, y: 9.75)); path.addLine(to: .init(x: 4.5, y: 11.25))
      context.stroke(path, with: .foreground, style: .init(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
    }.frame(width: 18, height: 18).accessibilityHidden(true)
  }
}
