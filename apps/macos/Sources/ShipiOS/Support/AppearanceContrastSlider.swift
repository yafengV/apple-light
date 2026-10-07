import AppKit
import CoreText
import SwiftUI

struct AppearanceContrastSlider: NSViewRepresentable {
  @Binding var value: Double
  let label: String
  let theme: AppearanceThemeShare.Theme
  let available: () -> Bool
  @Environment(\.isEnabled) private var enabled
  @Environment(\.layoutDirection) private var direction
  @Environment(\.appAppearance) private var appearance
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> Control {
    let view = Control(); view.owner = context.coordinator; view.setAccessibilityElement(true); view.setAccessibilityRole(.slider)
    view.setAccessibilityMinValue(0); view.setAccessibilityMaxValue(100); return view
  }
  func updateNSView(_ view: Control, context: Context) {
    context.coordinator.parent = self
    view.isEnabled = enabled && available(); view.value = value; view.rtl = direction == .rightToLeft
    view.accent = AppearanceRGBA(hex: theme.accent); view.surface = AppearanceRGBA(hex: theme.surface)
    view.ink = appearance.resolvedColors["textForeground"].nativeColor
    let font = appearance.nativeFont(size: 13)
    view.font = NSFont(descriptor: font.fontDescriptor.addingAttributes([.featureSettings: [[
      NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
      NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector
    ]]]), size: font.pointSize) ?? font
    view.setAccessibilityLabel(label); view.publishAccessibilityValue()
    view.needsDisplay = true
    if !view.isEnabled {
      DispatchQueue.main.async { [weak view] in
        guard let view, view.owner?.canAct(view) != true, view.window?.firstResponder === view else { return }
        view.window?.makeFirstResponder(nil)
      }
    }
  }
  static func dismantleNSView(_ view: Control, coordinator: Coordinator) { coordinator.active = false; view.owner = nil }
  static func rangeValue(_ value: Double) -> Double { min(100, max(0, floor((value.isFinite ? value : 50) + 0.5))) }
  final class Control: NSControl {
    weak var owner: Coordinator?
    var value: Double = 45; var rtl = false
    var accent = AppearanceRGBA(hex: "#339cff"); var surface = AppearanceRGBA.white
    var ink = NSColor.labelColor
    func publishAccessibilityValue() {
      let next = NSNumber(value: rangeValue(value)), previous = accessibilityValue() as? NSNumber
      setAccessibilityValue(next)
      if let previous, previous != next { NSAccessibility.post(element: self, notification: .valueChanged) }
    }
    private var dragOffset: CGFloat?
    private var paletteKey = ""; private var palette: NSImage?
    override var intrinsicContentSize: NSSize { .init(width: 192, height: 36) }
    override var acceptsFirstResponder: Bool { isEnabled && owner?.canAct(self) == true }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }
    override func becomeFirstResponder() -> Bool { let result = super.becomeFirstResponder(); needsDisplay = true; return result }
    override func resignFirstResponder() -> Bool { let result = super.resignFirstResponder(); dragOffset = nil; needsDisplay = true; return result }
    var track: NSRect { .init(x: rtl ? 46 : 0, y: bounds.midY - 1, width: max(20, bounds.width - 46), height: 2) }
    var thumbX: CGFloat { track.minX + 10 + (track.width - 20) * (rtl ? 1 - rangeValue(value) / 100 : rangeValue(value) / 100) }
    var thumb: NSRect { .init(x: thumbX - 10, y: bounds.midY - 10, width: 20, height: 20) }
    override func draw(_ dirtyRect: NSRect) {
      let path = NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1)
      NSGraphicsContext.saveGraphicsState(); path.addClip()
      gradient()?.draw(in: track, from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.5)
      NSGraphicsContext.restoreGraphicsState()
      NSGraphicsContext.saveGraphicsState()
      let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.08); shadow.shadowBlurRadius = 2; shadow.shadowOffset = .init(width: 0, height: -1); shadow.set()
      ink.withAlphaComponent(isEnabled ? 1 : 0.5).setFill(); NSBezierPath(ovalIn: thumb).fill()
      NSGraphicsContext.restoreGraphicsState()
      if window?.firstResponder === self {
        NSColor.keyboardFocusIndicatorColor.setStroke(); let focus = NSBezierPath(ovalIn: thumb.insetBy(dx: -3, dy: -3)); focus.lineWidth = 2; focus.stroke()
      }
      let paragraph = NSMutableParagraphStyle(); paragraph.alignment = rtl ? .left : .right
      let text = NSAttributedString(string: AppearanceFontSize.text(value), attributes: [.font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: ink, .paragraphStyle: paragraph])
      text.draw(in: .init(x: rtl ? 0 : bounds.maxX - 36, y: bounds.midY - text.size().height / 2, width: 36, height: text.size().height))
    }
    private func gradient() -> NSImage? {
      let width = max(1, Int(track.width.rounded(.up))), key = "\(accent.hex)/\(surface.hex)/\(width)"
      if paletteKey == key { return palette }; paletteKey = key
      let space = CGColorSpace(name: CGColorSpace.sRGB)!
      guard let context = CGContext(data: nil, width: width, height: 2, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
      let a = [accent.red, accent.green, accent.blue], s = [surface.red, surface.green, surface.blue]
      let mixed = CGColor(colorSpace: space, components: zip(a, s).map { CGFloat((Double($0.0) * 0.35 + Double($0.1) * 0.65) / 255) } + [1])!
      let solid = CGColor(colorSpace: space, components: a.map { CGFloat($0) / 255 } + [1])!
      guard let gradient = CGGradient(colorsSpace: space, colors: [mixed, solid, solid] as CFArray, locations: [0, 0.32, 1]) else { return nil }
      context.drawLinearGradient(gradient, start: .zero, end: .init(x: width, y: 0), options: [])
      guard let image = context.makeImage() else { return nil }; palette = NSImage(cgImage: image, size: .init(width: width, height: 2)); return palette
    }
    override func mouseDown(with event: NSEvent) {
      guard owner?.canAct(self) == true else { return }
      let point = convert(event.locationInWindow, from: nil)
      guard track.contains(point) || thumb.contains(point) else { return }
      window?.makeFirstResponder(self)
      dragOffset = thumb.contains(point) ? point.x - thumbX : 0
      if !thumb.contains(point) { move(to: point.x) }
    }
    override func mouseDragged(with event: NSEvent) { guard dragOffset != nil else { return }; move(to: convert(event.locationInWindow, from: nil).x) }
    override func mouseUp(with event: NSEvent) { dragOffset = nil }
    private func move(to x: CGFloat) {
      guard owner?.canAct(self) == true else { dragOffset = nil; return }
      let fraction = (x - (dragOffset ?? 0) - track.minX - 10) / max(1, track.width - 20)
      owner?.choose((rtl ? 1 - fraction : fraction) * 100, in: self)
    }
    override func keyDown(with event: NSEvent) {
      guard owner?.canAct(self) == true else { super.keyDown(with: event); return }
      let current = rangeValue(value), next: Double
      switch event.keyCode {
      case 123: next = current + (rtl ? 1 : -1)
      case 124: next = current + (rtl ? -1 : 1)
      case 125: next = current - 1
      case 126: next = current + 1
      case 116: next = current + 10
      case 121: next = current - 10
      case 115: next = 0
      case 119: next = 100
      default: super.keyDown(with: event); return
      }
      owner?.choose(next, in: self)
    }
    override func accessibilityPerformIncrement() -> Bool { owner?.choose(rangeValue(value) + 1, in: self) ?? false }
    override func accessibilityPerformDecrement() -> Bool { owner?.choose(rangeValue(value) - 1, in: self) ?? false }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { dragOffset = nil } }
  }
  @MainActor final class Coordinator {
    var parent: AppearanceContrastSlider; var active = true
    init(_ parent: AppearanceContrastSlider) { self.parent = parent }
    func canAct(_ view: Control) -> Bool { active && parent.enabled && parent.available() && view.isEnabled && !view.isHiddenOrHasHiddenAncestor && view.window != nil && view.window?.attachedSheet == nil && WindowModalInteraction.allows(view) }
    @discardableResult func choose(_ value: Double, in view: Control) -> Bool {
      guard canAct(view) else { return false }; let next = rangeValue(value)
      if next != rangeValue(parent.value) { parent.value = next }
      view.value = parent.value; view.publishAccessibilityValue(); view.needsDisplay = true; return true
    }
  }
}
