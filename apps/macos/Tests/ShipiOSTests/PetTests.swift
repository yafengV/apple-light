import AppKit
import XCTest

@testable import ShipiOS

final class PetTests: XCTestCase {
  private func root() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }

  private func atlasData(width: Int = 1_536, height: Int = 1_872) throws -> Data {
    let bitmap = try XCTUnwrap(NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    NSColor.systemBlue.setFill()
    NSRect(x: 20, y: height - 180, width: 120, height: 120).fill()
    NSGraphicsContext.restoreGraphicsState()
    return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
  }

  func testPreferencesRoundTripValidationAndPermissions() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let preferences = PetPreferences(selected: .mini, visible: true, scale: 2)
    try PetStorage.save(preferences, root: root)
    let loaded = try PetStorage.load(root: root).0
    XCTAssertEqual(loaded.selected, .mini)
    XCTAssertTrue(loaded.visible)
    XCTAssertEqual(loaded.scale, 1.6)
    let attributes = try FileManager.default.attributesOfItem(
      atPath: PetStorage.preferencesURL(root: root).path)
    XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
  }

  func testAtlasValidationAndFrameCropping() throws {
    let data = try atlasData()
    XCTAssertEqual(try PetStorage.validateAsset(data), NSSize(width: 1_536, height: 1_872))
    let image = try XCTUnwrap(NSImage(data: data))
    let frame = try XCTUnwrap(PetAtlas.frame(image: image, row: 0, column: 0))
    XCTAssertEqual(frame.size, NSSize(width: 192, height: 208))
    XCTAssertNil(PetAtlas.frame(image: image, row: 9, column: 0))
    XCTAssertThrowsError(try PetStorage.validateAsset(atlasData(width: 100, height: 100)))
  }

  @MainActor func testStoreImportsSelectsAndRemovesCustomPet() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.loadPets()
    XCTAssertTrue(store.importCustomPet(try atlasData(), name: " Test Pet "))
    XCTAssertEqual(store.petPreferences.selected, .custom)
    XCTAssertEqual(store.petPreferences.customName, "Test Pet")
    XCTAssertNotNil(store.petCustomImage)
    let restored = WorkspaceStore(dataRoot: root)
    await restored.loadPets()
    XCTAssertEqual(restored.petPreferences.selected, .custom)
    XCTAssertNotNil(restored.petCustomImage)
    XCTAssertTrue(restored.removeCustomPet())
    XCTAssertEqual(restored.petPreferences.selected, .codey)
    XCTAssertFalse(restored.petPreferences.hasCustomPet)
  }

  @MainActor func testPetCommandsToggleWithoutSendingDraft() async {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.loadPets()
    store.draft = "/pet"
    XCTAssertTrue(store.handleComposerCommand())
    XCTAssertTrue(store.petPreferences.visible)
    XCTAssertEqual(store.draft, "")
    store.draft = "/pet"
    XCTAssertTrue(store.handleComposerCommand())
    XCTAssertFalse(store.petPreferences.visible)
    XCTAssertTrue(store.runs.isEmpty)
  }

  @MainActor func testPetShortcutCanUseOptionOnlyAndPersists() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("shortcuts.json")
    let shortcuts = ShortcutPreferences(file: file)
    try shortcuts.set(ShortcutBinding("⌥P"), for: "pet")
    XCTAssertEqual(shortcuts.label("pet"), "⌥P")
    XCTAssertThrowsError(try shortcuts.set(ShortcutBinding("⌥U"), for: "settings"))
    XCTAssertEqual(ShortcutPreferences(file: file).label("pet"), "⌥P")
  }
}
