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

  func testListsOnlyKnownExistingOutputsAndReadsBoundedLogs() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let artifact = TaskSummaryArtifact(runID: "run", title: "Build", directory: root)
    XCTAssertTrue(artifact.outputs.isEmpty)

    let bytes = Data(repeating: 65, count: 20)
    try bytes.write(to: root.appendingPathComponent("stdout.log"))
    try FileManager.default.createDirectory(at: root.appendingPathComponent("build.xcresult"),
      withIntermediateDirectories: true)
    try Data("unrelated".utf8).write(to: root.appendingPathComponent("secret.txt"))
    XCTAssertEqual(artifact.outputs.map(\.name), ["stdout.log", "build.xcresult"])
    let log = try XCTUnwrap(artifact.outputs.first)
    XCTAssertEqual(try log.readLog(maxBytes: 10).text, "AAAAAAAAAA")
    XCTAssertTrue(try log.readLog(maxBytes: 10).truncated)
    XCTAssertFalse(try log.readLog(maxBytes: 20).truncated)

    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("outside".utf8).write(to: outside)
    defer { try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("stderr.log"),
      withDestinationURL: outside)
    XCTAssertEqual(artifact.outputs.map(\.name), ["stdout.log", "build.xcresult"])
  }
}
