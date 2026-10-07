import Foundation

enum DockIconPreference: String, Codable, CaseIterable, Identifiable, Sendable {
  case appDefault = "app-default"
  case adaptive = "shipios-system"
  var id: String { rawValue }
  var title: String { self == .appDefault ? "使用 ShipiOS Dock 图标" : "使用自适应 Dock 图标" }
  func moved(by delta: Int) -> Self {
    let index = Self.allCases.firstIndex(of: self)!
    return Self.allCases[(index + delta + Self.allCases.count) % Self.allCases.count]
  }
}
