import Foundation

/// Project identity and deep-link draft identity are independent. The serialized
/// owner remains compatible with existing drafts, content IDs and window routes.
struct WorkspaceDraftIdentity: Equatable {
  let project: String?
  let linkID: UUID?
  var projectKey: String { project ?? "" }
  var owner: String {
    "new:\(project ?? "none")" + (linkID.map { ":link:\($0.uuidString)" } ?? "")
  }

  init(project: String?, linkID: UUID? = nil) {
    self.project = project; self.linkID = linkID
  }

  init?(owner: String, knownProjects: Set<String>) {
    guard owner.hasPrefix("new:") else { return nil }
    let payload = String(owner.dropFirst(4))
    guard !payload.utf8.contains(0) else { return nil }
    // A real configured directory can contain the same delimiter as a draft.
    if payload.hasPrefix("/"), knownProjects.contains(payload) {
      self.init(project: payload); return
    }
    if let delimiter = payload.range(of: ":link:", options: .backwards),
      let id = UUID(uuidString: String(payload[delimiter.upperBound...])),
      String(payload[delimiter.upperBound...]) == id.uuidString {
      let base = String(payload[..<delimiter.lowerBound])
      guard base == "none" || base.hasPrefix("/") else { return nil }
      self.init(project: base == "none" ? nil : base, linkID: id)
    } else {
      guard payload == "none" || payload.hasPrefix("/") else { return nil }
      self.init(project: payload == "none" ? nil : payload)
    }
  }
}
