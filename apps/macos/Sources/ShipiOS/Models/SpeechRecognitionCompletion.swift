import Foundation

/// Keeps interim text available until Speech returns a final result or the finish deadline expires.
struct SpeechRecognitionCompletion {
  private(set) var latest = ""
  private(set) var finishing = false
  private(set) var completed = false

  mutating func receive(_ text: String?, isFinal: Bool, hasError: Bool) -> Bool {
    guard !completed else { return false }
    if let text { latest = text }
    if isFinal || hasError {
      completed = true
      return true
    }
    return false
  }

  mutating func beginFinishing() -> Bool {
    guard !completed, !finishing else { return false }
    finishing = true
    return true
  }

  mutating func finishAfterTimeout() -> Bool {
    guard finishing, !completed else { return false }
    completed = true
    return true
  }

  mutating func stop() -> String {
    completed = true
    return latest.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
