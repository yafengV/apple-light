import AppKit

/// Public 80×60 previews, including the two independent system-mode halves.
@MainActor enum AppearanceModeArtwork {
  static let resourceBundle = ShipiOSResources.bundle
  private static let images = NSCache<NSString, NSImage>()

  static func image(_ name: String, accent: AppearanceRGBA) -> NSImage? {
    let key = name + accent.hex
    if let cached = images.object(forKey: key as NSString) { return cached }
    let size = NSSize(width: name.hasPrefix("system-") ? 40 : 80, height: 60)
    guard let base = raster(name + "-base", size: size), let mask = raster(name + "-accent", size: size) else { return nil }
    let image = NSImage(size: size, flipped: false) { rect in
      base.draw(in: rect)
      NSGraphicsContext.saveGraphicsState()
      let context = NSGraphicsContext.current?.cgContext
      context?.beginTransparencyLayer(auxiliaryInfo: nil)
      mask.draw(in: rect); accent.nativeColor.setFill(); rect.fill(using: .sourceIn)
      context?.endTransparencyLayer(); NSGraphicsContext.restoreGraphicsState()
      return true
    }
    image.isTemplate = false; images.setObject(image, forKey: key as NSString); return image
  }

  private static func raster(_ name: String, size: NSSize) -> NSImage? {
    let image = NSImage(size: size)
    for scale in 1...3 {
      let resource = name + (scale == 1 ? "" : "@\(scale)x")
      guard let url = resourceBundle.url(forResource: resource, withExtension: "png", subdirectory: "ThemePreviews"),
        let data = try? Data(contentsOf: url), let bitmap = NSBitmapImageRep(data: data) else { return nil }
      bitmap.size = size; image.addRepresentation(bitmap)
    }
    return image
  }

  static func draw(_ mode: AppearanceMode, in rect: NSRect, accent: AppearanceRGBA) {
    if mode == .system {
      let half = rect.width / 2
      image("system-light", accent: accent)?.draw(in: .init(x: rect.minX, y: rect.minY, width: half, height: rect.height),
        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
      image("system-dark", accent: accent)?.draw(in: .init(x: rect.minX + half, y: rect.minY, width: half, height: rect.height),
        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    } else {
      image(mode.rawValue, accent: accent)?.draw(in: rect, from: .zero, operation: .sourceOver,
        fraction: 1, respectFlipped: true, hints: nil)
    }
  }
}
