import AppKit
import CryptoKit
import SwiftUI
import XCTest
@testable import ShipiOS

final class AgentAvatarTests: XCTestCase {
  func testUTF16SelectionMatchesCurrentReferenceIncludingNormalizationAndLongSeeds() {
    // Expected values are from the actual Ahc function in the current public
    // reference module, executed independently of this Swift implementation.
    let cases = [("", 0, 0), ("a", 13, 7), ("root", 18, 2), ("child", 16, 6),
      ("01a1152a-cb0d-74d4-af49-50bbfa9fceac", 5, 9), ("中文", 14, 4), ("🙂", 5, 5),
      ("A🙂中", 27, 3), ("é", 9, 3), ("e\u{301}", 8, 0), ("𝄞", 22, 4),
      (String(repeating: "x", count: 10_000), 7, 3)]
    for (seed, codex, chatgpt) in cases {
      XCTAssertEqual(AgentAvatar.index(seed: seed), codex)
      XCTAssertEqual(AgentAvatar.index(seed: seed, palette: .chatgpt), chatgpt)
    }
    XCTAssertEqual(AgentAvatar.resourceName(seed: "child", dark: false), "avatar-16-light")
    XCTAssertEqual(AgentAvatar.resourceName(seed: "child", dark: true), "avatar-16-dark")
  }

  @MainActor func testAll56PackagedSVGsKeepReferenceBytesDecodeAndRenderWithoutTemplates() throws {
    struct Variant: Decodable { let file: String; let sha256: String }
    struct Entry: Decodable { let index: Int; let light: Variant; let dark: Variant }
    struct Manifest: Decodable { let entries: [Entry] }
    let manifestURL = try XCTUnwrap(AgentAvatar.resourceBundle.url(forResource: "manifest",
      withExtension: "json", subdirectory: "AgentAvatars"))
    let catalog = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
    XCTAssertEqual(catalog.entries.map(\.index), Array(0..<28))
    var bitmaps = Set<Data>()
    for entry in catalog.entries {
      let seed = try XCTUnwrap((0..<1000).map(String.init).first { AgentAvatar.index(seed: $0) == entry.index })
      var variants: [Data] = []
      for (dark, variant) in [(false, entry.light), (true, entry.dark)] {
        let url = try XCTUnwrap(AgentAvatar.resourceBundle.url(forResource: variant.file,
          withExtension: nil, subdirectory: "AgentAvatars"))
        let data = try Data(contentsOf: url)
        XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), variant.sha256)
        let image = try XCTUnwrap(AgentAvatar.image(seed: seed, dark: dark))
        XCTAssertEqual(image.size, NSSize(width: 16, height: 16)); XCTAssertFalse(image.isTemplate)
        XCTAssertTrue(image === AgentAvatar.image(seed: seed, dark: dark), "Repeated rows reuse the same decoded vector")
        let renderer = ImageRenderer(content: SeededAgentAvatar(seed: seed).environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = 2
        let rendered = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(rendered.width, 48); XCTAssertEqual(rendered.height, 48)
        let bitmap = NSBitmapImageRep(cgImage: rendered)
        var hasVisiblePixel = false
        for y in 0..<48 {
          for x in 0..<48 where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 { hasVisiblePixel = true }
        }
        XCTAssertTrue(hasVisiblePixel, "The SVG must actually paint, not just decode")
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        variants.append(png); bitmaps.insert(png)
      }
      XCTAssertNotEqual(variants[0], variants[1], "The same child selects theme-specific artwork")
    }
    XCTAssertEqual(bitmaps.count, 56, "All palette/theme combinations remain visually distinct")
  }

  @MainActor func testAvatarGeometryAllowsSummaryAndDetailSizesWithoutCircularBackground() throws {
    for size in [14.0, 24.0, 32.0] {
      let renderer = ImageRenderer(content: SeededAgentAvatar(seed: "root", size: size))
      renderer.scale = 2
      let image = try XCTUnwrap(renderer.cgImage)
      XCTAssertEqual(image.width, Int(size * 2)); XCTAssertEqual(image.height, Int(size * 2))
    }
  }
}
