import Foundation
import Security
import XCTest

@testable import ShipiOS

final class ModelCredentialIsolationTests: XCTestCase {
  private func remove(service: String, account: String) {
    SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
      kSecAttrAccount: account] as CFDictionary)
  }

  @MainActor func testIndependentServiceCredentialsSurviveConfigurationRestartWithoutCrossingAccounts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let identity = UUID().uuidString.lowercased()
    let accountA = "https://a-\(identity).invalid/v1", accountB = "https://b-\(identity).invalid/v1"
    defer {
      remove(service: "dev.shipios.desktop.model-api", account: accountA)
      remove(service: "dev.shipios.desktop.model-api", account: accountB)
      try? FileManager.default.removeItem(at: root)
    }
    try ModelKeychain.save("fixture-credential-A", account: accountA)
    try ModelKeychain.save("fixture-credential-B", account: accountB)
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    var config = ModelConfiguration()
    config.baseURL = accountA; config.model = "fixture-model-A"; config.apiProtocol = .codexResponses
    try store.saveModelConfiguration(config)
    var second = config; second.baseURL = accountB; second.model = "fixture-model-B"
    try store.saveModelConfiguration(second)
    XCTAssertEqual(try ModelKeychain.read(account: store.modelConfiguration.credentialAccount), "fixture-credential-B")
    try store.saveModelConfiguration(config)
    XCTAssertEqual(try ModelKeychain.read(account: store.modelConfiguration.credentialAccount), "fixture-credential-A")
    await store.shutdown()
    let restored = WorkspaceStore(dataRoot: root)
    await restored.restore()
    XCTAssertEqual(restored.modelConfiguration, config)
    XCTAssertEqual(try ModelKeychain.read(account: restored.modelConfiguration.credentialAccount), "fixture-credential-A")
    let file = root.appendingPathComponent("model.json")
    let contents = try String(contentsOf: file)
    XCTAssertFalse(contents.contains("fixture-credential"))
    XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
    await restored.shutdown()
  }

  func testForeignCodexKeychainItemDoesNotSupplyShipiOSCredential() throws {
    let account = "https://foreign-\(UUID().uuidString).invalid/v1"
    let foreignService = "com.openai.codex"
    defer { remove(service: foreignService, account: account) }
    let result = SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: foreignService,
      kSecAttrAccount: account, kSecValueData: Data("foreign-fixture-credential".utf8)] as CFDictionary, nil)
    XCTAssertEqual(result, errSecSuccess)
    XCTAssertNil(try ModelKeychain.read(account: account))
  }
}
