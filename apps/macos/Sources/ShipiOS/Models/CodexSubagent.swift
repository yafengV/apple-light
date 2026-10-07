import Foundation

enum CodexSubagentStatus: String, Codable {
  case pendingInit, running, interrupted, completed, failed, shutdown, notLoaded
  var working: Bool { self == .pendingInit || self == .running }
  var label: String {
    switch self {
    case .pendingInit: "正在启动"
    case .running: "正在工作"
    case .interrupted: "已中断"
    case .completed: "已完成"
    case .failed: "失败"
    case .shutdown: "已关闭"
    case .notLoaded: "未运行"
    }
  }
}

struct CodexSubagent: Codable, Equatable, Identifiable {
  var rootThreadID: String
  var threadID: String
  var parentThreadID: String?
  var nickname: String?
  var role: String?
  var depth: Int?
  var model: String?
  var reasoningEffort: String?
  var status: CodexSubagentStatus
  var loaded: Bool
  var preview: String?
  var observedAtMs: Int
  var recencyAtMs: Int? = nil
  var objective: String? = nil
  var startedAtMs: Int? = nil
  var lastAssistantMessageAtMs: Int? = nil
  var overviewStatus: SubagentOverviewStatus {
    switch status {
    case .pendingInit: .waiting
    case .running: .active
    case .completed, .notLoaded: .done
    case .failed, .interrupted, .shutdown: .hidden
    }
  }
  var id: String { rootThreadID + ":" + threadID }
  var working: Bool { loaded && status.working }
  var acceptsInput: Bool { loaded && status != .shutdown && status != .notLoaded }
  var displayName: String {
    [nickname, role].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty } ?? "子任务"
  }

  mutating func disconnect() {
    loaded = false
    if status.working { status = .notLoaded }
  }
}

/// Overview membership is presentation only. Keep terminal children in the task
/// so an already-open detail can retain history, drafts and a retry composer.
enum SubagentOverviewStatus { case active, waiting, done, hidden }

struct SubagentOverview {
  let visible: [CodexSubagent]
  var active: [CodexSubagent] { visible.filter { $0.overviewStatus != .done } }
  var waiting: [CodexSubagent] { visible.filter { $0.overviewStatus == .waiting } }
  var running: [CodexSubagent] { visible.filter { $0.overviewStatus == .active } }
  var done: [CodexSubagent] { visible.filter { $0.overviewStatus == .done } }
  init(_ agents: [CodexSubagent]) {
    visible = agents.enumerated().filter { $0.element.overviewStatus != .hidden }
      .sorted {
        let left = $0.element.recencyAtMs ?? 0, right = $1.element.recencyAtMs ?? 0
        return left == right ? $0.offset < $1.offset : left > right
      }.map(\.element)
  }
}

/// A snapshot is applied only after every ordered chunk arrives. Partial or
/// malformed frames must not hide an active child or enable Stop for a peer.
struct CodexSubagentSnapshotAssembler {
  private struct Wire: Decodable {
    let threadId: String
    let parentThreadId: String?
    let nickname: String?
    let role: String?
    let depth: Int?
    let model: String?
    let reasoningEffort: String?
    let status: CodexSubagentStatus
    let loaded: Bool
    let preview: String?
    let recencyAtMs: Int?
    let objective: String?
    let startedAtMs: Int?
    let lastAssistantMessageAtMs: Int?
  }
  private var snapshotID: String?
  private var rootID: String?
  private var total = 0
  private var observedAt = 0
  private var revision = 0
  private(set) var completedRevision: Int?
  private var rows: [CodexSubagent] = []

  mutating func append(_ event: JSONValue, root: String) -> [CodexSubagent]? {
    guard event["type"].text == "shipios_subagent_snapshot",
      let id = event["snapshotId"].text, UUID(uuidString: id) != nil,
      let offset = event["offset"].int, offset >= 0,
      let count = event["total"].int, count >= 0,
      let timestamp = event["observedAtMs"].int, timestamp >= 0,
      let version = event["revision"].int, version > 0,
      let done = event["done"].boolean,
      case .array(let values) = event["agents"], values.count <= 64,
      let decoded = try? event["agents"].decode([Wire].self),
      decoded.allSatisfy({ UUID(uuidString: $0.threadId) != nil && $0.threadId != root
        && ($0.parentThreadId == nil || UUID(uuidString: $0.parentThreadId!) != nil)
        && ($0.loaded || !$0.status.working)
        && ([$0.recencyAtMs, $0.startedAtMs, $0.lastAssistantMessageAtMs]
          .allSatisfy { $0.map { $0 >= 0 } ?? true }) }) else { self = .init(); return nil }
    if offset == 0 {
      self = .init(); snapshotID = id; rootID = root; total = count; observedAt = timestamp; revision = version
    }
    guard snapshotID == id, rootID == root, count == total, timestamp == observedAt,
      version == revision, offset == rows.count,
      values.count <= total - min(total, offset), offset <= total,
      done == (offset + values.count == total), done || !values.isEmpty else {
      self = .init(); return nil
    }
    let incoming = decoded.map { row in
      CodexSubagent(rootThreadID: root, threadID: row.threadId, parentThreadID: row.parentThreadId,
        nickname: row.nickname, role: row.role, depth: row.depth, model: row.model,
        reasoningEffort: row.reasoningEffort, status: row.status, loaded: row.loaded,
        preview: row.preview, observedAtMs: timestamp, recencyAtMs: row.recencyAtMs, objective: row.objective,
        startedAtMs: row.startedAtMs, lastAssistantMessageAtMs: row.lastAssistantMessageAtMs)
    }
    let ids = rows.map(\.id) + incoming.map(\.id)
    guard Set(ids).count == ids.count else { self = .init(); return nil }
    rows.append(contentsOf: incoming)
    guard done else { return nil }
    let completed = rows
    self = .init()
    completedRevision = version
    return completed
  }
}
