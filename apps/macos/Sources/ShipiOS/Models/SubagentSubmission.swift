import CryptoKit
import Foundation

/// Local metadata is displayed only after matching an actual native user item.
/// A lost RPC acknowledgement must neither fabricate history nor release assets
/// that the child may already have accepted.
struct SubagentSubmission: Codable, Equatable, Identifiable {
  enum Phase: String, Codable { case pending, accepted, unconfirmed }
  let id: UUID
  let taskID: String
  let rootThreadID: String
  let childThreadID: String
  let message: ChatMessage
  let wireDigest: String
  let wireByteCount: Int
  let expectedTurnID: String?
  var turnID: String?
  var phase: Phase = .pending

  init(taskID: String, rootThreadID: String, childThreadID: String,
    message: ChatMessage, wireText: String, expectedTurnID: String?) {
    id = UUID(); self.taskID = taskID; self.rootThreadID = rootThreadID
    self.childThreadID = childThreadID; self.message = message
    wireDigest = Self.digest(wireText); wireByteCount = wireText.utf8.count
    self.expectedTurnID = expectedTurnID
  }

  func matches(_ entry: SubagentTranscriptEntry, root: URL) -> Bool {
    guard entry.kind == .user, entry.text.utf8.count == wireByteCount,
      Self.digest(entry.text) == wireDigest,
      turnID == nil || turnID == entry.turnID,
      expectedTurnID == nil || expectedTurnID == entry.turnID else { return false }
    // Compare canonical paths without opening arbitrary paths from a rollout.
    let expected = message.images.map {
      ImageAttachmentStorage.url($0, root: root).resolvingSymlinksInPath().standardizedFileURL.path
    }
    let actual = entry.localImagePaths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path }
    return expected == actual
  }

  private static func digest(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

extension SubagentTranscript {
  /// Records must already be scoped to this task/root/child by the caller.
  /// Consume once, so repeated inputs remain separate native history entries.
  func attaching(_ records: [SubagentSubmission], root: URL) -> SubagentTranscript {
    var result = self, remaining = records
    for index in result.entries.indices where result.entries[index].kind == .user {
      let entry = result.entries[index]
      let matches = remaining.indices.filter { remaining[$0].matches(entry, root: root) }
      guard let match = matches.first(where: { remaining[$0].phase == .accepted }) ?? matches.first else { continue }
      let record = remaining.remove(at: match)
      result.entries[index].text = record.message.content
      result.entries[index].images = record.message.images
      result.entries[index].files = record.message.files
      result.entries[index].hasAttachmentMetadata = true
    }
    return result
  }
}
