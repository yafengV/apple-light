import XCTest
@testable import ShipiOS

final class PluginHookCatalogTests: XCTestCase {
  private func fixture() throws -> (URL, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = root.appendingPathComponent("Source")
    let manifest = source.appendingPathComponent(".codex-plugin/plugin.json")
    try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"id":"hook-fixture","name":"Hook Fixture"}"#.utf8).write(to: manifest)
    return (root, source)
  }

  private func write(_ text: String, to file: URL) throws {
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: file)
  }

  func testDefaultHookFileDisplaysCommandButNeverRunsIt() throws {
    let (root, source) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let marker = root.appendingPathComponent("ran")
    try write("""
      {"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"touch \(marker.path)"}]}]}}
      """, to: source.appendingPathComponent("hooks/hooks.json"))
    let dataRoot = root.appendingPathComponent("Data")
    _ = try PluginStorage.install(from: source, root: dataRoot)
    let found = try PluginHookCatalog.declarations(pluginID: "hook-fixture", root: dataRoot)
    XCTAssertEqual(found.map(\.event), ["SessionStart"])
    XCTAssertEqual(found.map(\.source), ["./hooks/hooks.json"])
    XCTAssertEqual(found.first?.command, "touch \(marker.path)")
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
  }

  func testExplicitHookPathOverridesDefaultFile() throws {
    let (root, source) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try write(#"{"id":"hook-fixture","name":"Hook Fixture","hooks":"./hooks/selected.json"}"#,
      to: source.appendingPathComponent(".codex-plugin/plugin.json"))
    try write(#"{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"selected"}]}]}}"#,
      to: source.appendingPathComponent("hooks/selected.json"))
    try write(#"{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"default"}]}]}}"#,
      to: source.appendingPathComponent("hooks/hooks.json"))
    let dataRoot = root.appendingPathComponent("Data")
    _ = try PluginStorage.install(from: source, root: dataRoot)
    XCTAssertEqual(try PluginHookCatalog.declarations(pluginID: "hook-fixture", root: dataRoot)
      .map(\.command), ["selected"])
  }

  func testPathTraversalIsRejected() throws {
    let (root, source) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try write(#"{"id":"hook-fixture","name":"Hook Fixture","hooks":"./../outside.json"}"#,
      to: source.appendingPathComponent(".codex-plugin/plugin.json"))
    let dataRoot = root.appendingPathComponent("Data")
    _ = try PluginStorage.install(from: source, root: dataRoot)
    XCTAssertThrowsError(try PluginHookCatalog.declarations(pluginID: "hook-fixture", root: dataRoot))
  }

  func testPortableInlineHookOverridesLegacyManifest() throws {
    let (root, source) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try write(#"{"id":"hook-fixture","name":"Hook Fixture","hooks":{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"legacy"}]}]}}}"#,
      to: source.appendingPathComponent(".codex-plugin/plugin.json"))
    try write(#"{"$schema":"https://agent-plugins.org/schemas/1.0.0/plugin.schema.json","name":"hook-fixture","extensions":{"com.openai":{"hooks":{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"portable"}]}]}}}}}"#,
      to: source.appendingPathComponent("plugin.json"))
    let dataRoot = root.appendingPathComponent("Data")
    _ = try PluginStorage.install(from: source, root: dataRoot)
    let found = try PluginHookCatalog.declarations(pluginID: "hook-fixture", root: dataRoot)
    XCTAssertEqual(found.map(\.event), ["Stop"])
    XCTAssertEqual(found.map(\.command), ["portable"])
    XCTAssertEqual(found.map(\.source), ["./plugin.json"])
  }

  func testSymlinkedHookFileIsRejectedAfterInstall() throws {
    let (root, source) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let hook = source.appendingPathComponent("hooks/hooks.json")
    try write(#"{"hooks":{}}"#, to: hook)
    let dataRoot = root.appendingPathComponent("Data")
    _ = try PluginStorage.install(from: source, root: dataRoot)
    let installed = PluginStorage.packageURL(root: dataRoot, id: "hook-fixture")
      .appendingPathComponent("hooks/hooks.json")
    try FileManager.default.removeItem(at: installed)
    try FileManager.default.createSymbolicLink(at: installed, withDestinationURL: hook)
    XCTAssertThrowsError(try PluginHookCatalog.declarations(pluginID: "hook-fixture", root: dataRoot))
  }

  func testPortableOnlyPackageLoadsDefaultHookFile() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Portable")
    try write(#"{"$schema":"https://agent-plugins.org/schemas/1.0.0/plugin.schema.json","name":"portable-hooks"}"#,
      to: source.appendingPathComponent("plugin.json"))
    try write(#"{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo ready"}]}]}}"#,
      to: source.appendingPathComponent("hooks/hooks.json"))
    let dataRoot = root.appendingPathComponent("Data")
    let installed = try PluginStorage.install(from: source, root: dataRoot)
    XCTAssertEqual(installed.installed.first?.id, "portable-hooks")
    XCTAssertEqual(try PluginHookCatalog.declarations(pluginID: "portable-hooks", root: dataRoot)
      .map(\.command), ["echo ready"])
  }
}
