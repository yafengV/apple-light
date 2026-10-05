import Foundation

/// Placement is local to each timeline. Pending requests retain their first anchor.
struct ChildElicitationProjection {
  struct Input: Equatable {
    let root: String?
    let turns: [String]
    let requests: [String]
  }
  enum Entry: Equatable, Identifiable {
    case turn(String)
    case child(String, after: String?)
    var id: String {
      switch self { case .turn(let id): id; case .child(let id, _): "child-elicitation:" + id }
    }
  }
  private(set) var root: String?
  private(set) var entries: [Entry] = []
  mutating func update(_ input: Input) {
    entries = projected(input)
    root = input.root
  }
  func projected(_ input: Input) -> [Entry] {
    Self.project(turns: input.turns, requests: input.requests, previous: root == input.root ? entries : [])
  }
  static func project(turns: [String], requests: [String], previous: [Entry]) -> [Entry] {
    let base = turns.map(Entry.turn)
    guard !requests.isEmpty else { return base }
    let pending = Set(requests)
    guard !base.isEmpty else {
      return previous.filter { if case .child(let id, _) = $0 { pending.contains(id) } else { false } }
    }
    let visible = Set(turns)
    var old: [String: (Int, String?)] = [:]
    for (index, entry) in previous.enumerated() {
      if case .child(let id, let anchor) = entry { old[id] = (index, anchor) }
    }
    let children: [Entry] = requests.enumerated().sorted {
      let a = old[$0.element]?.0 ?? Int.max, b = old[$1.element]?.0 ?? Int.max
      return a == b ? $0.offset < $1.offset : a < b
    }.map { _, id in
      guard let existing = old[id] else { return .child(id, after: turns.last) }
      guard let anchor = existing.1, !visible.contains(anchor) else { return .child(id, after: existing.1) }
      let index = previous.firstIndex(of: .turn(anchor)) ?? 0
      let fallback = previous.prefix(index).reversed().compactMap { entry -> String? in
        if case .turn(let id) = entry, visible.contains(id) { return id }; return nil
      }.first
      return .child(id, after: fallback)
    }
    func following(_ anchor: String?) -> [Entry] {
      children.filter { if case .child(_, let after) = $0 { after == anchor } else { false } }
    }
    return following(nil) + turns.flatMap { [.turn($0)] + following($0) }
  }
}

struct SubagentElicitationPresentation: Equatable, Identifiable {
  let agent: CodexSubagent
  let request: SubagentElicitationRequest
  var id: String { agent.id + ":" + request.id }
}
