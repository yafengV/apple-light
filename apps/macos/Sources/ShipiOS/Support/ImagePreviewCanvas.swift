import AppKit
import SwiftUI

struct ImagePreviewCanvas: NSViewRepresentable {
  let image: CGImage
  let requestedPercent: Double?
  let onChange: (ImagePreviewZoom) -> Void
  let onDismiss: () -> Void

  func makeNSView(context: Context) -> Canvas {
    let canvas = Canvas()
    canvas.drawsBackground = false
    canvas.hasHorizontalScroller = true
    canvas.hasVerticalScroller = true
    canvas.autohidesScrollers = true
    canvas.scrollerStyle = .overlay
    canvas.documentView = canvas.picture
    canvas.picture.owner = canvas
    return canvas
  }
  func updateNSView(_ canvas: Canvas, context: Context) {
    canvas.changed = onChange
    canvas.dismiss = onDismiss
    canvas.update(image: image, requested: requestedPercent)
  }
  static func dismantleNSView(_ canvas: Canvas, coordinator: ()) {
    canvas.active = false
    canvas.changed = nil
    canvas.dismiss = nil
  }

  final class Canvas: NSScrollView {
    let picture = Picture()
    var active = true
    var changed: ((ImagePreviewZoom) -> Void)?
    var dismiss: (() -> Void)?
    private(set) var zoom = ImagePreviewZoom(naturalSize: .zero, viewport: .zero)
    private var source: CGImage?
    private var notification = UUID()
    override var acceptsFirstResponder: Bool { active }

    func update(image: CGImage, requested: Double?) {
      guard active else { return }
      let replaced = source !== image
      guard replaced || zoom.requestedPercent != requested else { return }
      let old = zoom
      if replaced {
        source = image
        picture.image = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        zoom.naturalSize = CGSize(width: image.width, height: image.height)
      }
      zoom.viewport = contentSize
      zoom.requestedPercent = requested
      render(from: old, reset: replaced || requested == nil)
    }
    override func layout() {
      super.layout()
      guard active, zoom.viewport != contentSize else { return }
      let old = zoom
      zoom.viewport = contentSize
      render(from: old, reset: zoom.requestedPercent == nil)
    }
    func setZoom(_ percent: Double, anchor: CGPoint? = nil) {
      guard active, source != nil else { return }
      let old = zoom
      zoom.requestedPercent = zoom.clamp(percent)
      render(from: old, anchor: anchor)
    }
    private func render(from old: ImagePreviewZoom, anchor: CGPoint? = nil, reset: Bool = false) {
      let offset = reset ? CGPoint.zero : zoom.offset(from: old,
        oldOffset: contentView.bounds.origin,
        anchor: anchor ?? CGPoint(x: old.viewport.width / 2, y: old.viewport.height / 2))
      picture.frame.size = zoom.documentSize
      picture.imageRect = zoom.imageRect
      contentView.scroll(to: zoom.clampedOffset(offset))
      reflectScrolledClipView(contentView)
      picture.needsDisplay = true
      window?.invalidateCursorRects(for: picture)
      notification = UUID()
      let token = notification, value = zoom
      DispatchQueue.main.async { [weak self] in
        guard let self, self.active, self.notification == token else { return }
        self.changed?(value)
      }
    }
    func pan(to point: CGPoint) {
      contentView.scroll(to: zoom.clampedOffset(point))
      reflectScrolledClipView(contentView)
    }
    override func magnify(with event: NSEvent) {
      let point = contentView.convert(event.locationInWindow, from: nil)
      setZoom(zoom.percent * (1 + event.magnification),
        anchor: CGPoint(x: point.x - contentView.bounds.minX, y: point.y - contentView.bounds.minY))
    }
    override func scrollWheel(with event: NSEvent) {
      if event.modifierFlags.contains(.control) {
        let point = contentView.convert(event.locationInWindow, from: nil)
        setZoom(zoom.percent * exp(event.scrollingDeltaY / 200),
          anchor: CGPoint(x: point.x - contentView.bounds.minX, y: point.y - contentView.bounds.minY))
      } else { super.scrollWheel(with: event) }
    }
  }

  final class Picture: NSView {
    weak var owner: Canvas?
    var image: NSImage?
    var imageRect = CGRect.zero
    private var drag: (point: CGPoint, offset: CGPoint)?
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
      NSGraphicsContext.current?.imageInterpolation = .high
      image?.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1,
        respectFlipped: true, hints: nil)
    }
    override func resetCursorRects() {
      if let owner, owner.zoom.percent > owner.zoom.fitPercent + 0.001 {
        addCursorRect(visibleRect, cursor: .openHand)
      }
    }
    override func mouseDown(with event: NSEvent) {
      guard let owner, owner.active else { return }
      guard imageRect.contains(convert(event.locationInWindow, from: nil)) else {
        owner.dismiss?(); return
      }
      window?.makeFirstResponder(owner)
      drag = (event.locationInWindow, owner.contentView.bounds.origin)
    }
    override func mouseDragged(with event: NSEvent) {
      guard let drag, let owner, owner.active else { return }
      owner.pan(to: CGPoint(x: drag.offset.x - (event.locationInWindow.x - drag.point.x),
        y: drag.offset.y + (event.locationInWindow.y - drag.point.y)))
    }
    override func mouseUp(with event: NSEvent) { drag = nil }
  }
}
