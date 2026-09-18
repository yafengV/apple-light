import XCTest

@testable import ShipiOS

final class GoalModeTests: XCTestCase {
  func testParserConsumesOnlyFinalProtocolLine() {
    XCTAssertEqual(
      GoalResponseParser.parse("work\n\nSHIPIOS_GOAL_STATUS: continue"),
      ParsedGoalResponse(text: "work", signal: .continueWorking))
    XCTAssertEqual(
      GoalResponseParser.parse("done\nSHIPIOS_GOAL_STATUS: complete\n"),
      ParsedGoalResponse(text: "done", signal: .complete))
    XCTAssertEqual(
      GoalResponseParser.parse("SHIPIOS_GOAL_STATUS: complete\nmore text"),
      ParsedGoalResponse(text: "SHIPIOS_GOAL_STATUS: complete\nmore text", signal: nil))
  }

  func testLegacyLibraryDefaultsGoalSessionsAndRoundTrips() throws {
    let legacy = try JSONDecoder().decode(WorkspaceLibrary.self, from: Data("{}".utf8))
    XCTAssertTrue(legacy.goalSessions.isEmpty)
    var library = legacy
    library.goalSessions["task"] = GoalSession(
      definition: GoalDefinition(
        objective: "Ship it", successCriteria: ["Tests pass"], maxIterations: 4),
      status: .paused, iteration: 2, lastRunID: "run")
    let restored = try JSONDecoder().decode(
      WorkspaceLibrary.self, from: JSONEncoder().encode(library))
    XCTAssertEqual(restored.goalSessions, library.goalSessions)
  }

  @MainActor func testGoalConfigurationValidatesAndSlashCommandOpensEditor() {
    let store = WorkspaceStore()
    XCTAssertFalse(store.configureGoal(GoalDefinition(objective: "", successCriteria: [])))
    XCTAssertNotNil(store.error)
    store.error = nil
    XCTAssertTrue(store.configureGoal(GoalDefinition(
      objective: "  Outcome  ", successCriteria: ["  First  ", "", "Second"],
      maxIterations: 99)))
    XCTAssertEqual(store.pendingGoal?.objective, "Outcome")
    XCTAssertEqual(store.pendingGoal?.successCriteria, ["First", "Second"])
    XCTAssertEqual(store.pendingGoal?.maxIterations, 10)
    XCTAssertEqual(store.chatMode, .goal)

    store.clearPendingGoal()
    store.draft = "/goal"
    XCTAssertTrue(store.handleComposerCommand())
    XCTAssertTrue(store.showingGoalEditor)
    XCTAssertTrue(store.draft.isEmpty)
  }

  func testArchivedTaskDeletionRemovesGoalSession() {
    var library = WorkspaceLibrary()
    let run = AgentRun(
      id: "run", kind: "chat", project: "", status: "succeeded", createdAt: 0,
      updatedAt: 0, request: .null, result: nil)
    library.attach(run, to: nil, note: "goal")
    library.tasks[0].archived = true
    library.goalSessions[library.tasks[0].id] = GoalSession(
      definition: GoalDefinition(objective: "Goal", successCriteria: ["Done"]))
    _ = library.deleteArchivedTasks([library.tasks[0].id])
    XCTAssertTrue(library.goalSessions.isEmpty)
  }
}
