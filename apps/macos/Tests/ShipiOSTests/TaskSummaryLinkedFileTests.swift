import XCTest

@testable import ShipiOS

final class TaskSummaryLinkedFileTests: XCTestCase {
  func testAssistantLinkedFilesMustExistInsideRunWorkspace() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let report = root.appendingPathComponent("report.md")
    try Data("report".utf8).write(to: report)
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("outside".utf8).write(to: outside)
    defer { try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.md"),
      withDestinationURL: outside)

    let reply = """
    [报告](report.md) [重复](report.md#L1) [缺失](missing.md)
    [外部](../\(outside.lastPathComponent)) [链接](https://example.com)
    [符号链接](escape.md) ` [代码](fake.md) `
    """
    let run = AgentRun(id: "run", kind: "chat", project: root.path, status: "succeeded",
      createdAt: 0, updatedAt: 0, request: .null,
      result: .object(["response": .string(reply)]))
    let files = TaskSummaryLinkedFiles.collect([run], rootForRun: { _ in root })
    XCTAssertEqual(files.map(\.path), ["report.md"])
    XCTAssertEqual(files.first?.runID, "run")
  }

  func testUserInputLinksAreNotOutputFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("input".utf8).write(to: root.appendingPathComponent("input.md"))
    let run = AgentRun(id: "run", kind: "chat", project: root.path, status: "succeeded",
      createdAt: 0, updatedAt: 0,
      request: .object(["prompt": .string("See [input](input.md)")]),
      result: .object(["response": .string("I read the input.")]))

    XCTAssertTrue(TaskSummaryLinkedFiles.collect([run], rootForRun: { _ in root }).isEmpty)
  }

  func testCoreResponseItemsProvideOutputLinks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("result".utf8).write(to: root.appendingPathComponent("result.md"))
    let items: [ChatResponseItem] = [
      .message(id: UUID(), text: "Created [result](result.md)."),
    ]
    let run = AgentRun(id: "core", kind: "chat", project: root.path, status: "succeeded",
      createdAt: 0, updatedAt: 0, request: .null,
      result: .object(["response_items": try ChatResponseItem.json(items)]))

    XCTAssertEqual(TaskSummaryLinkedFiles.collect([run], rootForRun: { _ in root })
      .map(\.title), ["result.md"])
  }
}
