import AppKit
import SwiftUI

struct AppearanceColorPickerCanvas: NSViewRepresentable {
  let value: AppearanceHSV
  let onChange: (AppearanceHSV) -> Void
  func makeNSView(context: Context) -> Canvas { Canvas() }
  func updateNSView(_ view: Canvas, context: Context) { view.value = value; view.onChange = onChange }
  static func dismantleNSView(_ view: Canvas, coordinator: ()) { view.onChange = nil }

  final class Canvas: NSView {
    var value = AppearanceHSV(hex: "#000000") { didSet { needsDisplay = true; color.needsDisplay = true; hue.needsDisplay = true; updateAccessibility() } }
    var onChange: ((AppearanceHSV) -> Void)?
    private var paletteImage: NSImage?
    private var paletteHue: Double?
    private var paletteSize = NSSize.zero
    let color = Slider(axis: .color), hue = Slider(axis: .hue)
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { .init(width: 200, height: 200) }
    override init(frame: NSRect) {
      super.init(frame: frame); addSubview(color); addSubview(hue); color.canvas = self; hue.canvas = self
      color.setAccessibilityLabel("Color"); hue.setAccessibilityLabel("Hue")
      for slider in [color, hue] { slider.setAccessibilityRole(.slider) }
      updateAccessibility()
    }
    convenience init() { self.init(frame: .init(x: 0, y: 0, width: 200, height: 200)) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
      super.layout()
      color.frame = .init(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - 36))
      hue.frame = .init(x: 0, y: max(0, bounds.height - 24), width: bounds.width, height: 24)
    }
    private func updateAccessibility() {
      color.setAccessibilityValue("Saturation \(Int(value.saturation.rounded()))%, Brightness \(Int(value.brightness.rounded()))%")
      hue.setAccessibilityMinValue(0); hue.setAccessibilityMaxValue(360); hue.setAccessibilityValue(NSNumber(value: value.hue.rounded()))
    }
    func change(_ slider: Slider, left: Double, top: Double, keyboard: Bool) {
      guard slider.acceptsFirstResponder, slider.window != nil else { return }
      let changed = keyboard ? value.stepping(slider.axis, left: left, top: top) : value.moving(slider.axis, left: left, top: top)
      value = changed; onChange?(changed)
    }
    override func draw(_ dirtyRect: NSRect) {
      guard let context = NSGraphicsContext.current?.cgContext else { return }
      context.saveGState(); defer { context.restoreGState() }
      context.addPath(CGPath(roundedRect: bounds, cornerWidth: 8, cornerHeight: 8, transform: nil)); context.clip()
      if paletteHue != value.hue.rounded() || paletteSize != bounds.size || paletteImage == nil {
        paletteImage = makePalette(); paletteHue = value.hue.rounded(); paletteSize = bounds.size
      }
      paletteImage?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    private func makePalette() -> NSImage? {
      let width = Int(ceil(bounds.width)), height = Int(ceil(bounds.height))
      guard width > 0, height > 36, let space = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
          space: space, bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
      // Blend before destination profile conversion; blending into AppKit's
      // calibrated backing space changes the saturation gradient's RGB values.
      context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
      context.setFillColorSpace(space)
      context.setFillColor([0, 0, 0, 1]); context.fill(bounds)
      let hueColor = AppearanceHSV(hue: value.hue.rounded(), saturation: 100, brightness: 100).color
      context.setFillColor([CGFloat(hueColor.red) / 255, CGFloat(hueColor.green) / 255, CGFloat(hueColor.blue) / 255, 1]); context.fill(color.frame)
      gradient(context, colors: [.white, .white.opacity(0)], locations: [0, 1], start: .zero, end: .init(x: bounds.width, y: 0), clip: color.frame)
      gradient(context, colors: [.black.opacity(0), .black], locations: [0, 1], start: .zero, end: .init(x: 0, y: color.frame.height), clip: color.frame)
      gradient(context, colors: ["#ff0000", "#ffff00", "#00ff00", "#00ffff", "#0000ff", "#ff00ff", "#ff0000"].map(AppearanceRGBA.init(hex:)),
        locations: [0, 0.17, 0.33, 0.5, 0.67, 0.83, 1], start: .init(x: 0, y: hue.frame.midY), end: .init(x: bounds.width, y: hue.frame.midY), clip: hue.frame)
      guard let image = context.makeImage() else { return nil }
      return NSImage(cgImage: image, size: bounds.size)
    }
    private func gradient(_ context: CGContext, colors: [AppearanceRGBA], locations: [CGFloat], start: CGPoint, end: CGPoint, clip: CGRect) {
      let components = colors.flatMap { [CGFloat($0.red) / 255, CGFloat($0.green) / 255, CGFloat($0.blue) / 255, CGFloat($0.alpha)] }
      guard let space = CGColorSpace(name: CGColorSpace.sRGB),
        let gradient = CGGradient(colorSpace: space, colorComponents: components, locations: locations, count: colors.count) else { return }
      context.saveGState(); context.clip(to: clip); context.drawLinearGradient(gradient, start: start, end: end, options: []); context.restoreGState()
    }
  }
  final class Slider: NSView {
    let axis: AppearanceHSV.Axis
    weak var canvas: Canvas?
    override var isFlipped: Bool { true }
    override var wantsDefaultClipping: Bool { false }
    override var acceptsFirstResponder: Bool { canvas?.onChange != nil && !isHiddenOrHasHiddenAncestor }
    override var canBecomeKeyView: Bool { acceptsFirstResponder && window != nil }
    init(axis: AppearanceHSV.Axis) { self.axis = axis; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    override func draw(_ dirtyRect: NSRect) {
      guard let value = canvas?.value else { return }
      let focused = window?.firstResponder === self, diameter: CGFloat = focused ? 30.8 : 28
      let center = CGPoint(x: bounds.width * (axis == .hue ? value.hue / 360 : value.saturation / 100),
        y: axis == .hue ? bounds.midY : bounds.height * (1 - value.brightness / 100))
      let circle = NSBezierPath(ovalIn: .init(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter))
      let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.2); shadow.shadowOffset = .init(width: 0, height: -2); shadow.shadowBlurRadius = 4
      NSGraphicsContext.saveGraphicsState(); shadow.set()
      (axis == .hue ? AppearanceHSV(hue: value.hue.rounded(), saturation: 100, brightness: 100).color : value.pointerColor).nativeColor.setFill(); circle.fill()
      NSColor.white.setStroke(); circle.lineWidth = 2; circle.stroke(); NSGraphicsContext.restoreGraphicsState()
    }
    override func mouseDown(with event: NSEvent) { guard acceptsFirstResponder else { return }; window?.makeFirstResponder(self); move(event) }
    override func mouseDragged(with event: NSEvent) { move(event) }
    private func move(_ event: NSEvent) {
      guard bounds.width > 0, bounds.height > 0 else { return }; let point = convert(event.locationInWindow, from: nil)
      canvas?.change(self, left: point.x / bounds.width, top: point.y / bounds.height, keyboard: false)
    }
    override func keyDown(with event: NSEvent) {
      let delta: (Double, Double)
      switch event.keyCode { case 123: delta = (-0.05, 0); case 124: delta = (0.05, 0); case 125: delta = (0, 0.05); case 126: delta = (0, -0.05); default: super.keyDown(with: event); return }
      canvas?.change(self, left: delta.0, top: delta.1, keyboard: true)
    }
    override func accessibilityPerformIncrement() -> Bool { guard acceptsFirstResponder, window != nil else { return false }; canvas?.change(self, left: 0.05, top: 0, keyboard: true); return true }
    override func accessibilityPerformDecrement() -> Bool { guard acceptsFirstResponder, window != nil else { return false }; canvas?.change(self, left: -0.05, top: 0, keyboard: true); return true }
  }
}
