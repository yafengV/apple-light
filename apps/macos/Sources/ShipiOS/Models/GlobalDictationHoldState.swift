struct GlobalDictationHoldState {
  private(set) var token: String?

  mutating func press(newToken: String) -> String? {
    guard token == nil else { return nil }
    token = newToken
    return newToken
  }

  mutating func release() -> String? {
    defer { token = nil }
    return token
  }
}
