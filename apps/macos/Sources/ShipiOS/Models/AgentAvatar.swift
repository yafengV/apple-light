import AppKit
import Foundation

enum AgentAvatarPalette { case codex, chatgpt
  var count: Int { self == .codex ? 28 : 10 }
}

/// Stable across app launches and platforms. The reference hashes UTF-16 units
/// modulo 2^31-1 at each step; Swift's process-randomized Hasher cannot be used.
enum AgentAvatar {
  static func index(seed: String, palette: AgentAvatarPalette = .codex) -> Int {
    var hash: UInt64 = 0
    for unit in seed.utf16 { hash = (hash * 31 + UInt64(unit)) % 2_147_483_647 }
    return Int(hash) % palette.count
  }

  static func resourceName(seed: String, dark: Bool, palette: AgentAvatarPalette = .codex) -> String {
    String(format: "avatar-%02d-%@", index(seed: seed, palette: palette), dark ? "dark" : "light")
  }

  static let resourceBundle = ShipiOSResources.bundle

  @MainActor private static let images = NSCache<NSString, NSImage>()

  @MainActor static func image(seed: String, dark: Bool, palette: AgentAvatarPalette = .codex) -> NSImage? {
    let name = resourceName(seed: seed, dark: dark, palette: palette)
    if let cached = images.object(forKey: name as NSString) { return cached }
    guard let url = resourceBundle.url(forResource: name, withExtension: "svg", subdirectory: "AgentAvatars"),
      let image = NSImage(contentsOf: url) else { return nil }
    image.isTemplate = false
    images.setObject(image, forKey: name as NSString)
    return image
  }
}
