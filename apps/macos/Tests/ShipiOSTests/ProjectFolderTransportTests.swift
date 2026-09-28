import XCTest
@testable import ShipiOS

final class ProjectFolderTransportTests: XCTestCase {
  private var server: Process!
  private var endpoint = ""
  override func setUpWithError() throws {
    server = Process()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Fixtures/model_server.py")
    server.arguments = ["-u", fixture.path]
    let pipe = Pipe()
    server.standardOutput = pipe
    server.standardError = FileHandle.nullDevice
    try server.run()
    let port = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard Int(port) != nil else { throw AgentFailure(message: "Local fixture could not start") }
    endpoint = "http://127.0.0.1:\(port)/v1"
  }
  override func tearDown() {
    if server?.isRunning == true { server.terminate(); server.waitUntilExit() }
  }

  @MainActor private func fixture(api: ModelAPIProtocol = .codexResponses) async throws
    -> (WorkspaceStore, URL, URL, URL, URL) {
    var repository = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    // Outside /tmp: default workspace-write otherwise also grants every /tmp path.
    let root = repository.appendingPathComponent(".cache/project-folders-\(UUID())")
      .resolvingSymlinksInPath().standardizedFileURL
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let primary = root.appendingPathComponent("Primary")
    let attached = root.appendingPathComponent("Attached with spaces")
    let outside = root.appendingPathComponent("Unattached")
    for directory in [primary, attached, outside] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"),
      agentExecutable: repository.appendingPathComponent("target/debug/shipios-agent"))
    await store.restore(); await store.open(primary)
    var config = ModelConfiguration()
    config.baseURL = endpoint
    config.model = api == .codexResponses ? "gpt-5.4" : "fixture"
    config.apiProtocol = api
    try store.saveModelConfiguration(config)
    store.library.agentRuntimePreferences.approvalPolicy = .never
    store.notificationPreferences = .init(timing: .never)
    return (store, root, primary, attached, outside)
  }

  @MainActor private func edit(_ store: WorkspaceStore, folders: [String]) throws {
    store.beginEditingProject(store.currentProjectKey)
    let request = try XCTUnwrap(store.editingProject)
    try store.saveProjectEdit(request, title: request.title, folders: folders)
    store.editingProject = nil
  }

  @MainActor private func probe(store: WorkspaceStore, primary: URL, attached: URL,
    outside: URL, mode: ChatMode = .standard, review: Bool = false) async throws -> (AgentRun, String) {
    let token = UUID().uuidString
    let payload = JSONValue.object(["token": .string(token), "primary": .string(primary.path),
      "attached": .string(attached.path), "outside": .string(outside.path)])
    let prompt = "SHIPIOS_MULTI_FOLDER_PROBE " + String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
    let reviewContext = review ? ModelCodeReviewContext(snapshot: ModelCodeReviewSnapshot(
      scope: .uncommitted, diff: prompt, repositoryRoot: primary.path), delivery: .inline) : nil
    let started = await store.startChat(prompt, mode: mode, review: reviewContext)
    let id = try XCTUnwrap(started, store.error ?? "No actual Core run")
    await store.modelTask(runID: id)?.value
    let run = try XCTUnwrap(store.library.chatRuns.first { $0.id == id })
    XCTAssertEqual(run.status, "succeeded", run.result?["message"].text ?? "")
    XCTAssertTrue(run.toolExecutions.contains { $0.toolName == "命令" })
    return (run, token)
  }

  @MainActor func testAttachedWriteThenDetachUsesSameCoreThreadWithoutGrantingOtherFolders() async throws {
    let (store, _, primary, attached, outside) = try await fixture()
    let (_, baseline) = try await probe(store: store, primary: primary, attached: attached, outside: outside)
    XCTAssertTrue(FileManager.default.fileExists(atPath: primary.appendingPathComponent(baseline + ".txt").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: attached.appendingPathComponent(baseline + ".txt").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent(baseline + ".txt").path))
    let original = try XCTUnwrap(store.selectedTask?.codexThreadID)
    try edit(store, folders: [attached.path])
    let (withFolder, added) = try await probe(store: store, primary: primary, attached: attached, outside: outside)
    XCTAssertEqual(withFolder.request["additional_folders"].items.compactMap(\.text), [attached.path])
    XCTAssertEqual(store.selectedTask?.codexThreadID, original)
    XCTAssertTrue(FileManager.default.fileExists(atPath: attached.appendingPathComponent(added + ".txt").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent(added + ".txt").path))
    let body = try JSONDecoder().decode(JSONValue.self,
      from: Data(try XCTUnwrap(withFolder.result?["response"].text).utf8))
    XCTAssertTrue(body.pretty.contains(baseline), "Resumed thread keeps its original turn history")
    XCTAssertTrue(body.pretty.contains(primary.path), "Execution cwd remains the primary folder")
    try edit(store, folders: [])
    let (removedRun, removed) = try await probe(store: store, primary: primary, attached: attached, outside: outside)
    XCTAssertTrue(removedRun.request["additional_folders"].items.isEmpty)
    XCTAssertEqual(store.selectedTask?.codexThreadID, original)
    XCTAssertTrue(FileManager.default.fileExists(atPath: primary.appendingPathComponent(removed + ".txt").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: attached.appendingPathComponent(removed + ".txt").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: attached.appendingPathComponent(added + ".txt").path))
    await store.shutdown()
  }

  @MainActor func testAttachedFoldersDoNotWeakenPlanReadOnlyAndSurviveAppRestart() async throws {
    let (store, root, primary, attached, outside) = try await fixture()
    let executable = store.executable
    try edit(store, folders: [attached.path])
    let (_, plan) = try await probe(store: store, primary: primary, attached: attached, outside: outside, mode: .plan)
    XCTAssertFalse(FileManager.default.fileExists(atPath: primary.appendingPathComponent(plan + ".txt").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: attached.appendingPathComponent(plan + ".txt").path))
    let threadID = store.selectedTask?.codexThreadID
    await store.shutdown()
    let reopened = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"), agentExecutable: executable)
    await reopened.restore(); await reopened.open(primary)
    reopened.notificationPreferences = .init(timing: .never)
    XCTAssertEqual(reopened.library.additionalFolders(for: primary.path), [attached.path])
    let (_, written) = try await probe(store: reopened, primary: primary, attached: attached, outside: outside)
    XCTAssertEqual(reopened.selectedTask?.codexThreadID, threadID)
    XCTAssertTrue(FileManager.default.fileExists(atPath: attached.appendingPathComponent(written + ".txt").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent(written + ".txt").path))
    await reopened.shutdown()
  }

  @MainActor func testBasicProtocolUsesPrimarySkillScopeAndUnavailableFolderDoesNotConsumeDraft() async throws {
    let (store, _, primary, attached, _) = try await fixture(api: .chatCompletions)
    try PluginStorage.createRepositorySkill(id: "main-skill", description: "PRIMARY-SKILL-PURPOSE",
      instructions: "primary body", project: primary)
    try PluginStorage.createRepositorySkill(id: "attached-skill", description: "SECONDARY-SKILL-PURPOSE",
      instructions: "attached body", project: attached)
    try edit(store, folders: [attached.path])
    await store.loadPlugins()
    let started = await store.startChat("skill-dependency-request-echo")
    let id = try XCTUnwrap(started, store.error ?? "No chat")
    await store.modelTask(runID: id)?.value
    let run = try XCTUnwrap(store.library.chatRuns.first { $0.id == id })
    let response = try XCTUnwrap(run.result?["response"].text)
    XCTAssertTrue(response.contains(attached.path))
    XCTAssertTrue(response.contains("PRIMARY-SKILL-PURPOSE"))
    XCTAssertFalse(response.contains("SECONDARY-SKILL-PURPOSE"))
    try FileManager.default.removeItem(at: attached)
    store.draft = "keep unavailable-folder draft"
    let count = store.library.chatRuns.count
    let rejected = await store.startChat(store.draft, consumeDraft: true)
    XCTAssertNil(rejected)
    XCTAssertEqual(store.library.chatRuns.count, count)
    XCTAssertEqual(store.draft, "keep unavailable-folder draft")
    XCTAssertTrue(store.error?.contains(attached.path) == true)
    await store.shutdown()
  }

  @MainActor func testReadOnlyReviewCannotWriteAttachedFoldersAndNormalFollowupKeepsPermission() async throws {
    let (store, _, primary, attached, outside) = try await fixture()
    try edit(store, folders: [attached.path])
    let (reviewRun, attempted) = try await probe(store: store, primary: primary,
      attached: attached, outside: outside, review: true)
    XCTAssertEqual(reviewRun.request["conversation_kind"].text, "review")
    XCTAssertEqual(reviewRun.request["additional_folders"].items.compactMap(\.text), [attached.path])
    for directory in [primary, attached, outside] {
      XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(attempted + ".txt").path))
    }
    let (_, normal) = try await probe(store: store, primary: primary, attached: attached, outside: outside)
    XCTAssertTrue(FileManager.default.fileExists(atPath: attached.appendingPathComponent(normal + ".txt").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent(normal + ".txt").path))
    await store.shutdown()
  }
}
