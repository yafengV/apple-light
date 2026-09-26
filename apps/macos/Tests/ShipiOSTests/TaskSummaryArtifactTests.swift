import XCTest
@testable import ShipiOS

final class TaskSummaryArtifactTests: XCTestCase {
  func testOnlyActualLocalOutputDirectoriesAppearAsArtifacts() {
    func run(_ id: String, kind: String, path: String?) -> AgentRun {
      AgentRun(id: id, kind: kind, project: "", status: "succeeded",
        createdAt: 0, updatedAt: 0, request: .null,
        result: path.map { .object(["artifactDirectory": .string($0)]) })
    }

    let runs = [
      run("chat", kind: "chat", path: "/private/tmp/input-attachment"),
      run("diagnosis", kind: "doctor", path: "/private/tmp/diagnosis-output"),
      run("invalid", kind: "build", path: "relative-output"),
      run("missing", kind: "build", path: nil),
    ]
    let artifacts = runs.summaryArtifacts
    XCTAssertEqual(artifacts.map(\.runID), ["diagnosis"])
    XCTAssertEqual(artifacts.first?.directory.path, "/private/tmp/diagnosis-output")
  }
}
