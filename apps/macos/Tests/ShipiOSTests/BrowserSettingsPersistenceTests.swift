import Foundation
import XCTest
@testable import ShipiOS

@MainActor final class BrowserSettingsPersistenceTests: XCTestCase {
  private func fixture() throws -> (WorkspaceStore, URL, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-settings-\(UUID())")
    let folder = root.appendingPathComponent("downloads", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    store.library.browserDownloadPreferences = .init(directory: folder.path, askWhereToSave: false)
    try store.library.save(to: root.appendingPathComponent("workspace.json"))
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return (store, root, folder)
  }

  private func blockSaving(_ root: URL) throws {
    let file = root.appendingPathComponent("workspace.json")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    try Data("block atomic replacement".utf8).write(to: file.appendingPathComponent("blocker"))
  }

  func testFailedPreferenceWritesKeepTheOriginalSettingsAndReportFailure() throws {
    let (store, root, _) = try fixture()
    let original = store.browserDownloadPreferences
    try blockSaving(root)
    XCTAssertFalse(store.setBrowserDownloadFolder(root))
    XCTAssertEqual(store.browserDownloadPreferences, original)
    XCTAssertNotNil(store.browserSettingsError)
    store.browserSettingsError = nil
    store.useSystemBrowserDownloadFolder()
    XCTAssertEqual(store.browserDownloadPreferences, original)
    XCTAssertNotNil(store.browserSettingsError)
    store.browserSettingsError = nil
    store.setBrowserAskWhereToSave(true)
    XCTAssertEqual(store.browserDownloadPreferences, original)
    XCTAssertNotNil(store.browserSettingsError)
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("workspace.json/blocker").path))
  }

  func testRetryPersistsPreferencesAndClearsTheFailure() throws {
    let (store, root, folder) = try fixture()
    try blockSaving(root)
    store.setBrowserAskWhereToSave(true)
    XCTAssertNotNil(store.browserSettingsError)
    try FileManager.default.removeItem(at: root.appendingPathComponent("workspace.json"))
    XCTAssertTrue(store.setBrowserDownloadFolder(root))
    XCTAssertNil(store.browserSettingsError)
    store.setBrowserAskWhereToSave(true)
    var restored = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    XCTAssertEqual(restored.browserDownloadPreferences, .init(directory: root.path, askWhereToSave: true))
    store.useSystemBrowserDownloadFolder()
    restored = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    XCTAssertEqual(restored.browserDownloadPreferences, .init(directory: nil, askWhereToSave: true))
    XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
  }

  func testFailedRecordRemovalKeepsRecordsAndProgressUntilRetry() throws {
    let (store, root, folder) = try fixture()
    let file = folder.appendingPathComponent("retained.txt")
    try Data("downloaded contents".utf8).write(to: file)
    let finished = BrowserDownloadRecord(id: UUID(), sourceURL: "http://localhost/fixture", filename: "retained.txt", destinationPath: file.path, status: .finished)
    let active = BrowserDownloadRecord(id: UUID(), sourceURL: "http://localhost/active", filename: "active", status: .downloading)
    store.library.browserDownloads = [finished, active]
    store.browserDownloadProgress = [finished.id: 1, active.id: 0.5]
    try store.library.save(to: root.appendingPathComponent("workspace.json"))
    let original = store.library.browserDownloads
    let progress = store.browserDownloadProgress
    try blockSaving(root)
    store.removeBrowserDownload(finished.id)
    XCTAssertEqual(store.library.browserDownloads, original)
    XCTAssertEqual(store.browserDownloadProgress, progress)
    XCTAssertNotNil(store.browserSettingsError)
    store.browserSettingsError = nil
    store.clearFinishedBrowserDownloads()
    XCTAssertEqual(store.library.browserDownloads, original)
    XCTAssertEqual(store.browserDownloadProgress, progress)
    XCTAssertNotNil(store.browserSettingsError)
    try FileManager.default.removeItem(at: root.appendingPathComponent("workspace.json"))
    store.clearFinishedBrowserDownloads()
    XCTAssertEqual(store.library.browserDownloads, [active])
    XCTAssertEqual(store.browserDownloadProgress, [active.id: 0.5])
    XCTAssertNil(store.browserSettingsError)
    XCTAssertEqual(try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json")).browserDownloads, [active])
    XCTAssertEqual(try Data(contentsOf: file), Data("downloaded contents".utf8))
    store.removeBrowserDownload(active.id)
    XCTAssertEqual(store.library.browserDownloads, [active])
  }

  func testPreferencesCannotPretendToPersistBeforeLibraryRecovery() throws {
    let (store, root, _) = try fixture()
    let original = store.browserDownloadPreferences
    let bytes = try Data(contentsOf: root.appendingPathComponent("workspace.json"))
    store.libraryLoaded = false
    XCTAssertFalse(store.setBrowserDownloadFolder(root))
    store.useSystemBrowserDownloadFolder()
    store.setBrowserAskWhereToSave(true)
    XCTAssertEqual(store.browserDownloadPreferences, original)
    XCTAssertNotNil(store.browserSettingsError)
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("workspace.json")), bytes)
  }
}
