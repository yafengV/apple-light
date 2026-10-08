struct GlobalDictationHoldState {
  private(set) var token: String?
  private var cancelledUntilRelease = false

  mutating func press(newToken: String) -> String? {
    guard token == nil, !cancelledUntilRelease else { return nil }
    token = newToken
    return newToken
  }

  mutating func release() -> String? {
    defer { token = nil; cancelledUntilRelease = false }
    return token
  }

  mutating func cancel(token: String) {
    guard self.token == token else { return }
    self.token = nil
    cancelledUntilRelease = true
  }
}
