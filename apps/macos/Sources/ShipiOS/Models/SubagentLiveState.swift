import Foundation
import CryptoKit

/// One child stream is shared by its windows; selections and drafts remain local.
/// Frames become visible only after complete UTF-8, identity and digest validation.
struct SubagentLiveState: Equatable {
  private(set) var events: [JSONValue] = []
  private(set) var error: String?
  private var streamID: String?
  private var sequence = 0
  private var retiredStreams: Set<String> = []
  private var pending: Pending?
  private struct Pending: Equatable {
    let stream: String
    let sequence: Int
    let eventID: String
    let total: Int
    let digest: String
    var data = Data()
  }

  mutating func append(_ frame: JSONValue, child: String) {
    guard error == nil else { return }
    do { try receive(frame, child: child) }
    catch { self.error = "子任务实时事件不完整，请重新加载历史。"; pending = nil }
  }

  private mutating func receive(_ frame: JSONValue, child: String) throws {
    func invalid() -> AgentFailure { AgentFailure(message: "Invalid child stream") }
    guard frame["type"].text == "shipios_subagent_event", frame["childThreadId"].text == child,
      let stream = frame["streamId"].text, UUID(uuidString: stream) != nil,
      let next = frame["sequence"].int, next > 0,
      let eventID = frame["eventId"].text,
      let offset = frame["offset"].int, offset >= 0,
      let total = frame["totalBytes"].int, total > 0,
      let digest = frame["sha256"].text, digest.count == 64,
      let done = frame["done"].boolean, let chunk = frame["chunk"].text else { throw invalid() }
    let data = Data(chunk.utf8)
    guard !data.isEmpty, data.count <= 48 * 1024, offset <= total,
      data.count <= total - offset, done == (offset + data.count == total) else { throw invalid() }
    if retiredStreams.contains(stream) { return }
    if streamID != stream {
      guard next == 1, offset == 0, pending == nil else { throw invalid() }
      if let old = streamID { retiredStreams.insert(old) }
      streamID = stream; sequence = 0; events = []
    }
    // Completed duplicates are harmless; pending duplicates/missing chunks are not.
    if next <= sequence { return }
    guard next == sequence + 1 else { throw invalid() }
    if pending == nil {
      guard offset == 0 else { throw invalid() }
      pending = Pending(stream: stream, sequence: next, eventID: eventID, total: total, digest: digest)
    }
    guard var current = pending, current.stream == stream, current.sequence == next,
      current.eventID == eventID, current.total == total, current.digest == digest,
      current.data.count == offset else { throw invalid() }
    current.data.append(data); pending = current
    guard done else { return }
    guard SHA256.hash(data: current.data).map({ String(format: "%02x", $0) }).joined() == digest else { throw invalid() }
    let event = try JSONDecoder().decode(JSONValue.self, from: current.data)
    guard case .object = event, event["type"].text != nil, event["thread_id"].text.map({ $0 == child }) ?? true else { throw invalid() }
    events.append(event); sequence = next; pending = nil
  }

  func merged(with history: [JSONValue]) -> [JSONValue] {
    // A reader claims the complete native queue from child creation. Replace
    // only history turns whose start is in that stream; retain older history.
    guard let first = events.first(where: { ["task_started", "turn_started"].contains($0["type"].text ?? "") }),
      let turn = first["turn_id"].text else { return history }
    if let index = history.firstIndex(where: {
      ["task_started", "turn_started"].contains($0["type"].text ?? "") && $0["turn_id"].text == turn
    }) {
      let liveTurns = Set(events.filter { ["task_started", "turn_started"].contains($0["type"].text ?? "") }
        .compactMap { $0["turn_id"].text })
      let liveTerminals = Set(events.filter { ["task_complete", "turn_aborted"].contains($0["type"].text ?? "") }
        .compactMap { $0["turn_id"].text })
      // Persistence can overtake IPC delivery. A newer durable turn/final reply
      // must not be replaced with an older incomplete live prefix.
      if history[index...].contains(where: { event in
        let type = event["type"].text ?? "", id = event["turn_id"].text ?? ""
        return (["task_started", "turn_started"].contains(type) && !liveTurns.contains(id))
          || (["task_complete", "turn_aborted"].contains(type) && !liveTerminals.contains(id))
      }) { return history }
      return Array(history[..<index]) + events
    }
    return history + events
  }
}
