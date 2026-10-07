import Foundation
import XCTest
@testable import ShipiOS

final class ShipiOSResourceBundleTests: XCTestCase {
  func testRelocatedAppUsesOnlyItsPackagedResources() throws {
    let root = try makeApplication(); defer { try? FileManager.default.removeItem(at: root) }
    let main = try XCTUnwrap(Bundle(url: root))
    let resources = try XCTUnwrap(main.resourceURL).appendingPathComponent("ShipiOS_ShipiOS.bundle")
    try FileManager.default.createDirectory(at: resources.appendingPathComponent("AgentAvatars"), withIntermediateDirectories: true)
    let marker = resources.appendingPathComponent("AgentAvatars/fixture.svg")
    try Data("packaged avatar".utf8).write(to: marker)
    var requestedDevelopment = false
    let selected = try XCTUnwrap(ShipiOSResources.resolve(main: main, development: { requestedDevelopment = true; return .main }))
    XCTAssertEqual(selected.bundleURL.standardizedFileURL, resources.standardizedFileURL)
    let url = try XCTUnwrap(selected.url(forResource: "fixture", withExtension: "svg", subdirectory: "AgentAvatars"))
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "packaged avatar")
    XCTAssertFalse(requestedDevelopment)
  }

  func testIncompleteAppCannotReadTheBuildCacheButNonAppUsesSwiftPM() throws {
    let root = try makeApplication(); defer { try? FileManager.default.removeItem(at: root) }
    let main = try XCTUnwrap(Bundle(url: root))
    var requestedDevelopment = false
    XCTAssertNil(ShipiOSResources.resolve(main: main, development: { requestedDevelopment = true; return .main }))
    XCTAssertFalse(requestedDevelopment)
    let nonApp = try XCTUnwrap(Bundle(url: try XCTUnwrap(main.resourceURL)))
    XCTAssertTrue(ShipiOSResources.resolve(main: nonApp, development: { requestedDevelopment = true; return nonApp }) === nonApp)
    XCTAssertTrue(requestedDevelopment)
  }

  private func makeApplication() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("resources-" + UUID().uuidString + ".app")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleIdentifier": "dev.shipios.resource-test", "CFBundlePackageType": "APPL", "CFBundleName": "Resource Test"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: root.appendingPathComponent("Contents/Info.plist"))
    return root
  }
}
