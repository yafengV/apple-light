import Foundation

struct ComputerUseApplication: Codable, Equatable, Hashable, Identifiable {
  let name: String
  let bundleIdentifier: String?
  let path: String

  var id: String { bundleIdentifier ?? path }
}

struct ComputerUsePreferences: Codable, Equatable {
  var anyAppEnabled = false
  var alwaysAllowedApplications: [ComputerUseApplication] = []

  func validated() -> Self {
    var result = self
    var seen = Set<String>()
    result.alwaysAllowedApplications = alwaysAllowedApplications.filter {
      !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !$0.path.isEmpty && seen.insert($0.id).inserted
    }
    return result
  }
}

enum ComputerUseStorage {
  static func file(root: URL) -> URL { root.appendingPathComponent("computer-use.json") }

  static func load(root: URL) throws -> ComputerUsePreferences {
    let url = file(root: root)
    do {
      return try JSONDecoder().decode(
        ComputerUsePreferences.self, from: Data(contentsOf: url)
      ).validated()
    } catch CocoaError.fileReadNoSuchFile {
      return ComputerUsePreferences()
    }
  }

  static func save(_ preferences: ComputerUsePreferences, root: URL) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = file(root: root)
    try JSONEncoder().encode(preferences.validated()).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}
