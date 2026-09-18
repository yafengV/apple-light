import XCTest

@testable import ShipiOS

final class ModelUsageTests: XCTestCase {
  func testConfigurationMigratesLegacyUsageRequestWithoutBreakingProvider() throws {
    let legacy = try JSONDecoder().decode(
      ModelConfiguration.self,
      from: Data(#"{"baseURL":"https://example.com/v1","model":"legacy"}"#.utf8))
    XCTAssertFalse(legacy.includeUsage)
    XCTAssertTrue(ModelConfiguration().includeUsage)
    let restored = try JSONDecoder().decode(
      ModelConfiguration.self, from: JSONEncoder().encode(ModelConfiguration()))
    XCTAssertTrue(restored.includeUsage)
  }

  func testRequestUsageOptionAndStoredRecordsAreAuthoritative() throws {
    var config = ModelConfiguration()
    config.model = "usage-model"
    let enabled = try JSONDecoder().decode(
      JSONValue.self,
      from: ImageAttachmentStorage.requestData(
        config: config, messages: [.init(role: "user", content: "hello")], root: nil))
    XCTAssertEqual(enabled["stream_options"]["include_usage"].boolean, true)
    config.includeUsage = false
    let disabled = try JSONDecoder().decode(
      JSONValue.self,
      from: ImageAttachmentStorage.requestData(
        config: config, messages: [.init(role: "user", content: "hello")], root: nil))
    XCTAssertEqual(disabled["stream_options"], .null)

    var library = WorkspaceLibrary()
    let usage = ModelTokenUsage(inputTokens: 100, outputTokens: 25, totalTokens: 125)
    let run = AgentRun(
      id: "usage", kind: "chat", project: "/project", status: "succeeded",
      createdAt: 1_000, updatedAt: 2_000,
      request: .object([
        "model": .string("usage-model"), "reasoning_effort": .string("high"),
      ]),
      result: .object(["response": .string("done"), "usage": usage.jsonValue]))
    library.projectNames["/project"] = "Demo"
    library.attach(run, to: nil, note: "measure")
    library.chatRuns = [run]
    XCTAssertEqual(library.modelUsageRecords.count, 1)
    XCTAssertEqual(library.modelUsageRecords[0].usage, usage)
    XCTAssertEqual(library.modelUsageRecords[0].taskTitle, "measure")
    XCTAssertEqual(library.modelUsageRecords[0].projectTitle, "Demo")
    XCTAssertEqual(library.modelUsageRecords[0].model, "usage-model")
    XCTAssertEqual(library.modelUsageRecords[0].reasoning, "high")
    XCTAssertEqual(library.modelUsageRecords[0].reasoningTitle, "高")
    XCTAssertEqual(library.modelUsageRecords[0].duration, 1)

    let second = AgentRun(
      id: "usage-2", kind: "chat", project: "/project", status: "succeeded",
      createdAt: 3_000, updatedAt: 4_000,
      request: .object(["model": .string("usage-model")]),
      result: .object([
        "response": .string("done again"),
        "usage": ModelTokenUsage(inputTokens: 50, outputTokens: 10).jsonValue,
      ]))
    library.tasks[0].runIDs.append(second.id)
    library.chatRuns.append(second)
    let grouped = try XCTUnwrap(library.modelUsageRecords.groupedByTask.first)
    XCTAssertEqual(grouped.taskID, "usage")
    XCTAssertEqual(grouped.sessionCount, 2)
    XCTAssertEqual(grouped.usage, ModelTokenUsage(inputTokens: 150, outputTokens: 35))
  }
}
