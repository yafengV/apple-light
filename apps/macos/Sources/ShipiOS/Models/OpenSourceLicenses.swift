import Foundation

struct OpenSourceLicense: Identifiable, Equatable {
  let id: String
  let title: String
  let text: String
}

enum OpenSourceLicenses {
  static func load(from directory: URL) throws -> [OpenSourceLicense] {
    let urls = try FileManager.default.contentsOfDirectory(at: directory,
      includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
      .filter { ["txt", "md"].contains($0.pathExtension.lowercased()) }
      .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    return try urls.map { url in
      guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
        throw CocoaError(.fileReadUnsupportedScheme)
      }
      let data = try Data(contentsOf: url)
      guard let text = String(data: data, encoding: .utf8) else {
        throw CocoaError(.fileReadInapplicableStringEncoding)
      }
      return OpenSourceLicense(id: url.lastPathComponent,
        title: url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-", with: " "),
        text: text)
    }
  }
}
