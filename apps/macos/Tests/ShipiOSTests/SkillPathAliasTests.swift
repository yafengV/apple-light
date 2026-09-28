import XCTest
@testable import ShipiOS

final class SkillPathAliasTests: XCTestCase {
  private func skills(count: Int = 20, root: String = "/tmp/ShipiOS/" + String(repeating: "Long folder 中文 \"quoted\"/", count: 5),
    summary: String = "Purpose") -> [PluginSkillReference] {
    let directory = URL(fileURLWithPath: root)
    return (0..<count).map { index in
      PluginSkillReference(pluginID: "example", pluginName: "Example", skillID: "skill-\(index)",
        title: "Skill \(index)", fileURL: directory.appendingPathComponent("skill-\(index)/SKILL.md"),
        mention: "example/skill-\(index)", summary: summary, catalogRoot: directory)
    }
  }

  private func absolute(_ skills: [PluginSkillReference]) -> [PluginSkillReference] {
    skills.map { var skill = $0; skill.catalogRoot = nil; return skill }
  }

  func testSelectionKeepsMoreIdentitiesThenDescriptionsThenSavesCost() throws {
    let entries = skills()
    let bounded = SkillDiscoveryContext.make(skills: entries, readTool: false, budget: .characters(3_000))
    let plain = SkillDiscoveryContext.make(skills: absolute(entries), readTool: false, budget: .characters(3_000))
    XCTAssertGreaterThan(bounded.skills.count, plain.skills.count)
    XCTAssertFalse(bounded.pathAliases.roots.isEmpty)
    let described = skills(summary: String(repeating: "Purpose 😀中文 ", count: 100))
    let compressed = SkillDiscoveryContext.make(skills: described, readTool: false, budget: .characters(8_000))
    let compressedPlain = SkillDiscoveryContext.make(skills: absolute(described), readTool: false, budget: .characters(8_000))
    XCTAssertEqual(compressed.skills.count, compressedPlain.skills.count)
    XCTAssertLessThan(compressed.shortenedDescriptionCharacters, compressedPlain.shortenedDescriptionCharacters)
    let roomy = SkillDiscoveryContext.make(skills: entries, readTool: true, budget: .tokens(8_000))
    let roomyPlain = SkillDiscoveryContext.make(skills: absolute(entries), readTool: true, budget: .tokens(8_000))
    XCTAssertEqual(roomy.shortenedDescriptionCharacters, 0)
    XCTAssertLessThan(roomy.metadataCost, roomyPlain.metadataCost)
    XCTAssertEqual(roomy.skills, entries, "Aliases must not change source URLs, identifiers or scope")
    for line in roomy.instructions.split(separator: "\n") where line.hasPrefix("{") {
      let row = try JSONDecoder().decode([String: String].self, from: Data(line.utf8))
      let entry = try XCTUnwrap(entries.first { $0.id == row["id"] })
      XCTAssertTrue(row["path"]?.hasPrefix("r0/") == true)
      XCTAssertEqual(roomy.pathAliases.expand(try XCTUnwrap(row["path"])), entry.fileURL.path)
    }
  }

  func testTableAndGuidanceAreChargedAndTinyBudgetsDoNotLeakAliasFragments() throws {
    let entries = skills(summary: String(repeating: "中文😀\"\n", count: 100))
    for budget in [SkillMetadataBudget.characters(0), .characters(1), .characters(100), .characters(1_500),
      .characters(8_000), .tokens(0), .tokens(1), .tokens(20), .tokens(800), .tokens(8_000)] {
      let catalog = SkillDiscoveryContext.make(skills: entries, readTool: true, budget: budget)
      XCTAssertLessThanOrEqual(catalog.metadataCost, budget.limit)
      let rows = catalog.instructions.split(separator: "\n").filter { $0.hasPrefix("{") }
      if !catalog.pathAliases.roots.isEmpty {
        let marker = catalog.omittedCount > 0 ? "\n部分技能因上下文预算未列出；不要猜测未列出技能的路径或标识。" : ""
        let measured = budget.cost(catalog.pathAliases.instructions)
          + rows.reduce(0) { $0 + budget.cost(String($1) + "\n") } + budget.cost(marker)
        XCTAssertEqual(catalog.metadataCost, measured)
        for line in catalog.instructions.split(separator: "\n") where line.hasPrefix("- {") {
          let root = try JSONDecoder().decode([String: String].self, from: Data(line.dropFirst(2).utf8))
          XCTAssertEqual(root["path"], entries.first?.catalogRoot?.path)
        }
      }
      let wholePrompt = SkillDiscoveryContext.make(skills: entries, readTool: true, maxCharacters: budget.limit)
      XCTAssertLessThanOrEqual(wholePrompt.instructions.count, budget.limit)
    }
    let single = SkillDiscoveryContext.make(skills: skills(count: 1, root: "/tmp/skills"),
      readTool: false, budget: .characters(8_000))
    XCTAssertTrue(single.pathAliases.roots.isEmpty, "An expensive root table must lose to absolute paths")
  }

  func testLongestRootComponentBoundaryAndInvalidExpansion() {
    let aliases = SkillPathAliases(roots: [.init(name: "r0", path: "/tmp/skills"),
      .init(name: "r1", path: "/tmp/skills/nested")])
    XCTAssertEqual(aliases.shorten("/tmp/skills/nested/item/SKILL.md"), "r1/item/SKILL.md")
    XCTAssertEqual(aliases.shorten("/tmp/skills-extra/item/SKILL.md"), "/tmp/skills-extra/item/SKILL.md")
    XCTAssertEqual(aliases.shorten("/tmp/skills"), "/tmp/skills")
    XCTAssertEqual(aliases.expand("r1/item/SKILL.md"), "/tmp/skills/nested/item/SKILL.md")
    for path in ["r2/item/SKILL.md", "r0/../private", "r0//item", "r0/./item", "r0/"] {
      XCTAssertNil(aliases.expand(path))
    }
    XCTAssertEqual(aliases.expand("/tmp/plain/SKILL.md"), "/tmp/plain/SKILL.md")
  }

  func testValidatedSourceRootsDeduplicateAndSingleSkillPackagesShareInstallRoot() {
    let one = skills(count: 1, root: "/tmp/Data/Plugins/one")[0]
    let two = skills(count: 1, root: "/tmp/Data/Plugins/two")[0]
    let multi = skills(count: 2, root: "/tmp/Data/Plugins/multi")
    var unrelated = skills(count: 1, root: "/tmp/unrelated")[0]
    unrelated.catalogRoot = URL(fileURLWithPath: "/tmp/elsewhere")
    let aliases = SkillPathAliases.make(skills: [one, two] + multi + [unrelated])
    XCTAssertEqual(aliases.roots.map(\.path), ["/tmp/Data/Plugins", "/tmp/Data/Plugins/multi"])
    XCTAssertEqual(aliases.shorten(one.fileURL.path), "r0/one/skill-0/SKILL.md")
    XCTAssertEqual(aliases.shorten(multi[0].fileURL.path), "r1/skill-0/SKILL.md")
    XCTAssertEqual(aliases.shorten(unrelated.fileURL.path), unrelated.fileURL.path)
    var disabled = one
    disabled.interface.allowImplicitInvocation = false
    let context = SkillDiscoveryContext.make(skills: [disabled], readTool: true, budget: .tokens(8_000))
    XCTAssertTrue(context.pathAliases.roots.isEmpty)
    XCTAssertFalse(context.instructions.contains("/tmp/Data/Plugins"))
  }
}
