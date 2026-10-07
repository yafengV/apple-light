import XCTest
@testable import ShipiOS

@MainActor final class ModelPowerSelectionTests: XCTestCase {
  struct Reference: Decodable {
    struct Case: Decodable {
      struct Step: Decodable {
        let current: String
        let decrease: String
        let increase: String
      }
      let name: String
      let efforts: [String]
      let defaultEffort: String?
      let current: String
      let referenceEfforts: [String]
      let resolved: String
      let steps: [Step]
    }
    let cases: [Case]
  }

  func reference() throws -> Reference {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "model_power_reference_656",
      withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
  }

  func testExplicitModelSliderStopsMatchPublicReferenceWithoutDefaultPosition() async throws {
    let catalog = ModelCatalog()
    for item in try reference().cases {
      await catalog.load(config: ModelConfiguration()) { _ in [ModelCatalogEntry(id: item.name,
        supportedReasoningEfforts: Set(item.efforts), reasoningOrder: item.efforts,
        defaultReasoningEffort: item.defaultEffort)] }
      let expected = item.referenceEfforts.count >= 2 ? item.referenceEfforts : []
      XCTAssertEqual(catalog.powerChoices(for: item.name, advanced: [.max, .ultra]), expected, item.name)
      XCTAssertTrue(catalog.availableReasoning(for: item.name, advanced: [.max, .ultra]).contains(""),
        "Service default remains available outside the slider")
    }
  }

  func testImplicitDefaultUsesReferenceEffectiveEffortWithoutChangingRequestConfiguration() async throws {
    let catalog = ModelCatalog()
    for item in try reference().cases {
      await catalog.load(config: ModelConfiguration()) { _ in [ModelCatalogEntry(id: item.name,
        supportedReasoningEfforts: Set(item.efforts), reasoningOrder: item.efforts,
        defaultReasoningEffort: item.defaultEffort)] }
      let options = catalog.powerChoices(for: item.name, advanced: [.max, .ultra])
      let expected = options.contains(item.resolved) ? item.resolved : nil
      XCTAssertEqual(catalog.powerReasoning(for: item.name, current: item.current,
        advanced: [.max, .ultra]), expected, item.name)
      XCTAssertNil(catalog.powerReasoning(for: item.name, current: "unsupported", advanced: [.max, .ultra]))
    }
    await catalog.load(config: ModelConfiguration()) { _ in [ModelCatalogEntry(id: "limited",
      supportedReasoningEfforts: ["low", "high", "ultra"], defaultReasoningEffort: "ultra")] }
    XCTAssertEqual(catalog.powerChoices(for: "limited", advanced: []), ["low", "high"])
    XCTAssertNil(catalog.powerReasoning(for: "limited", current: "", advanced: []))
    XCTAssertNil(catalog.powerReasoning(for: "limited", current: "ultra", advanced: []))
    XCTAssertEqual(catalog.powerReasoning(for: "limited", current: "", advanced: [.ultra]), "ultra")
    await catalog.load(config: ModelConfiguration()) { _ in throw AgentFailure(message: "Unavailable") }
    XCTAssertNil(catalog.powerReasoning(for: "limited", current: "low", advanced: [.ultra]))
  }

  func testPowerArrowTargetsMatchPublicReferenceAndClampAtBothEnds() async throws {
    let catalog = ModelCatalog()
    for item in try reference().cases {
      await catalog.load(config: ModelConfiguration()) { _ in [ModelCatalogEntry(id: item.name,
        supportedReasoningEfforts: Set(item.efforts), reasoningOrder: item.efforts,
        defaultReasoningEffort: item.defaultEffort)] }
      let options = catalog.powerChoices(for: item.name, advanced: [.max, .ultra])
      for step in item.steps {
        XCTAssertEqual(catalog.powerTarget(for: item.name, current: step.current,
          advanced: [.max, .ultra], increasing: false), options.isEmpty ? nil : step.decrease, item.name)
        XCTAssertEqual(catalog.powerTarget(for: item.name, current: step.current,
          advanced: [.max, .ultra], increasing: true), options.isEmpty ? nil : step.increase, item.name)
      }
      XCTAssertNil(catalog.powerTarget(for: item.name, current: "unsupported", advanced: [.max, .ultra], increasing: true))
    }
  }
}
