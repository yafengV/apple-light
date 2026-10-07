import AppKit
import CryptoKit
import XCTest
@testable import ShipiOS

@MainActor final class ThemeCardReferenceTests: XCTestCase {
  func testCurrentDistributedThemeGroupAndCardsUseNativeRadioSemanticsWithoutVisibleLabels() throws {
    let fixture = try reference()
    XCTAssertEqual(fixture["version"] as? String, "26.930.51102")
    XCTAssertEqual(fixture["sourceSHA256"] as? String, "91ef510e7631785df4c62c25f3b9018a0ca3c15ce3fa1b208f3cf8394abdf535")
    let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
    XCTAssertEqual(cases.count, 3)
    for item in cases {
      let mode = try XCTUnwrap(item["mode"] as? String)
      let group = try props(item["group"])
      XCTAssertEqual(group["role"] as? String, "radiogroup")
      XCTAssertEqual(group["className"] as? String, "grid w-68 max-w-full grid-cols-3 gap-4")
      let options = try XCTUnwrap(group["children"] as? [[String: Any]]).map { try props($0) }
      XCTAssertEqual(options.compactMap { $0["mode"] as? String }, ["system", "light", "dark"])
      XCTAssertEqual(options.filter { $0["selected"] as? Bool == true }.compactMap { $0["mode"] as? String }, [mode])
      let tooltip = try props(item["option"])
      XCTAssertEqual(tooltip["tooltipContent"] as? String, mode)
      let label = try props(tooltip["children"])
      let children = try XCTUnwrap(label["children"] as? [[String: Any]])
      XCTAssertEqual(children.count, 2) // Hidden radio + artwork; no visible label text.
      let input = try props(children[0]); XCTAssertEqual(input["type"] as? String, "radio")
      XCTAssertEqual(input["name"] as? String, "appearance-theme"); XCTAssertEqual(input["checked"] as? Bool, true)
      let preview = try props(item["preview"])
      XCTAssertEqual(preview["aria-hidden"] as? String, "true")
      XCTAssertEqual(preview["className"] as? String, "relative isolate block aspect-4/3 w-full overflow-hidden rounded-lg text-info peer-focus-visible:outline-2 peer-focus-visible:outline-offset-2 peer-focus-visible:outline-ring")
    }
  }

  func testAllPublicSVGsAndWebKitRasterResourcesArePackagedAndAccentCacheIsIndependent() throws {
    let fixture = try reference(), accent = AppearanceRGBA(hex: "#339cff")
    let artwork = try XCTUnwrap(fixture["artwork"] as? [[String: Any]])
    XCTAssertEqual(artwork.count, 4)
    for item in artwork {
      let name = try XCTUnwrap(item["name"] as? String)
      let url = try XCTUnwrap(AppearanceModeArtwork.resourceBundle.url(forResource: name, withExtension: "svg", subdirectory: "ThemePreviews"))
      let data = try Data(contentsOf: url)
      XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), item["sha256"] as? String)
      let width = name.hasPrefix("system-") ? 40 : 80
      for scale in 1...3 { for part in ["-base", "-accent"] {
        let png = try XCTUnwrap(AppearanceModeArtwork.resourceBundle.url(forResource: name + part + (scale == 1 ? "" : "@\(scale)x"), withExtension: "png", subdirectory: "ThemePreviews"))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: png)))
        XCTAssertEqual(bitmap.pixelsWide, width * scale); XCTAssertEqual(bitmap.pixelsHigh, 60 * scale)
        XCTAssertTrue(bitmap.hasAlpha)
      } }
      let image = try XCTUnwrap(AppearanceModeArtwork.image(name, accent: accent))
      XCTAssertEqual(image.size, .init(width: width, height: 60)); XCTAssertFalse(image.isTemplate)
      // NSCache may evict under memory pressure even while a caller retains an
      // image. Verify rendered output, not an identity guarantee it does not make.
      let repeated = try XCTUnwrap(AppearanceModeArtwork.image(name, accent: accent))
      let other = try XCTUnwrap(AppearanceModeArtwork.image(name, accent: .init(hex: "#df3758")))
      let pixels = try XCTUnwrap(image.tiffRepresentation)
      XCTAssertEqual(pixels, try XCTUnwrap(repeated.tiffRepresentation))
      XCTAssertNotEqual(pixels, try XCTUnwrap(other.tiffRepresentation))
    }
  }

  private func reference() throws -> [String: Any] {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "theme_card_reference_644", withExtension: "json", subdirectory: "Fixtures"))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  }
  private func props(_ value: Any?) throws -> [String: Any] {
    try XCTUnwrap((value as? [String: Any])?["props"] as? [String: Any])
  }
}
