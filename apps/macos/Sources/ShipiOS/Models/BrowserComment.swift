import Foundation

struct BrowserSelectionRect: Codable, Equatable, Sendable {
  let x: Double
  let y: Double
  let width: Double
  let height: Double
}

struct BrowserComment: Codable, Equatable, Identifiable, Sendable {
  var id = UUID()
  let reference: BrowserElementReference
  var body: String
}
