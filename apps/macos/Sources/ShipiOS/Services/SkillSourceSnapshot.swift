import CryptoKit
import Foundation

enum SkillSourceSnapshot {
  static func fingerprint(root: URL, projects: [String]) -> String {
    let root = root.resolvingSymlinksInPath()
    var hash = SHA256()
    func record(_ text: String) { hash.update(data: Data((text + "\n").utf8)) }
    func file(_ url: URL, within boundary: URL, content: Bool = true) {
      record(url.standardizedFileURL.path)
      guard url.standardizedFileURL.path.hasPrefix(boundary.standardizedFileURL.path + "/") else {
        record("outside"); return
      }
      let expected = boundary.resolvingSymlinksInPath().path
        + String(url.standardizedFileURL.path.dropFirst(boundary.standardizedFileURL.path.count))
      guard url.resolvingSymlinksInPath().path == expected else { record("linked"); return }
      do {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey,
          .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { record("invalid"); return }
        record("\(values.fileSize ?? -1)|\(values.contentModificationDate?.timeIntervalSince1970 ?? -1)|\(String(describing: values.fileResourceIdentifier))")
        if content, let size = values.fileSize, size <= 262_144 {
          hash.update(data: try Data(contentsOf: url))
        }
      } catch { record("error:\((error as NSError).code)") }
    }
    func skill(_ folder: URL) {
      let target = folder.resolvingSymlinksInPath()
      file(target.appendingPathComponent("SKILL.md"), within: target)
      file(target.appendingPathComponent("agents/openai.yaml"), within: target)
      if FileManager.default.fileExists(atPath: target.appendingPathComponent("SKILL.md").path),
        let interface = try? PluginStorage.skillInterface(in: target) {
        for icon in Set([interface.iconSmallURL, interface.iconLargeURL].compactMap { $0 })
          .sorted(by: { $0.path < $1.path }) {
          file(icon, within: target, content: false)
        }
      }
    }
    func directory(_ url: URL, within boundary: URL, recursive: Bool = false, followSkillLinks: Bool = false) {
      record(url.standardizedFileURL.path)
      let path = url.standardizedFileURL.path, rootPath = boundary.standardizedFileURL.path
      guard path.hasPrefix(rootPath + "/"), url.resolvingSymlinksInPath().path
        == boundary.resolvingSymlinksInPath().path + String(path.dropFirst(rootPath.count)) else {
        record("linked"); return
      }
      // The roots are private app directories or validated repository skill locations.
      // Only local skill children may be links; imported plugin packages stay contained.
      let manager = FileManager.default
      do {
        let children = try manager.contentsOfDirectory(at: url,
          includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
          .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for child in children {
          record(child.lastPathComponent)
          let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
          guard values.isDirectory == true || (followSkillLinks && values.isSymbolicLink == true) else { continue }
          if values.isSymbolicLink == true {
            guard followSkillLinks else { continue }
            record(child.resolvingSymlinksInPath().path)
            guard (try? child.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
          }
          skill(child)
          if recursive { directory(child, within: boundary, recursive: true) }
        }
      } catch { record("error:\((error as NSError).code)") }
    }
    file(root.appendingPathComponent("plugins.json"), within: root)
    directory(root.appendingPathComponent("Skills"), within: root, followSkillLinks: true)
    let packages = root.appendingPathComponent("Plugins")
    record(packages.path)
    if packages.resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().appendingPathComponent("Plugins").path,
      let folders = try? FileManager.default.contentsOfDirectory(at: packages,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
      for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
        directory(folder.appendingPathComponent("skills"), within: root, recursive: true)
      }
    }
    let scopes = Set(projects.filter { !$0.isEmpty }.flatMap {
      PluginStorage.repositorySkillScopes(project: URL(fileURLWithPath: $0, isDirectory: true))
        .map { $0.resolvingSymlinksInPath().path }
    })
    for path in scopes.sorted() {
      let scope = URL(fileURLWithPath: path)
      directory(scope.appendingPathComponent(".agents/skills"), within: scope, followSkillLinks: true)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
