import CryptoKit
import Foundation

/// Includes resource contents and executable bits, so editing a script restarts
/// the Core snapshot even when its Hook declaration is unchanged.
enum HookPluginResources {
  static func fingerprint(package: URL) throws -> String {
    guard package.resolvingSymlinksInPath().path == package.path else {
      throw AgentFailure(message: "插件目录不能是符号链接。")
    }
    var files: [(String, URL, Bool, UInt32)] = []
    var fileCount = 0
    var traversalError: Error?
    guard let enumerator = FileManager.default.enumerator(at: package,
      includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
      errorHandler: { _, error in traversalError = error; return false }) else {
      throw AgentFailure(message: "无法读取插件资源。")
    }
    for case let file as URL in enumerator {
      let filePath = (file.path as NSString).standardizingPath
      let value = try file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
      guard value.isSymbolicLink != true, value.isRegularFile == true || value.isDirectory == true,
        file.resolvingSymlinksInPath().path == filePath else {
        throw AgentFailure(message: "插件资源必须是插件内的普通文件或目录：\(file.lastPathComponent)。")
      }
      let relative = String(filePath.dropFirst(package.path.count + 1))
      if value.isRegularFile == true { fileCount += 1 }
      guard relative.split(separator: "/").count <= 32, fileCount <= PluginStorage.maximumFileCount,
        files.count < 10_000 else {
        throw AgentFailure(message: "插件资源超过数量或目录深度限制。")
      }
      let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
      let permission = (attributes[.posixPermissions] as? NSNumber)?.uint32Value ?? 0
      let mode = permission | (value.isDirectory == true ? 0o040000 : 0o100000)
      files.append((relative, file, value.isDirectory == true, mode))
    }
    if let traversalError { throw traversalError }
    var digest = SHA256(), total = 0
    for (relative, file, directory, mode) in files.sorted(by: { Array($0.0.utf8).lexicographicallyPrecedes(Array($1.0.utf8)) }) {
      let size = directory ? 0 : ((try FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.intValue ?? 0
      guard size >= 0, size <= PluginStorage.maximumPackageBytes - total else {
        throw AgentFailure(message: "插件资源超过 50 MiB。")
      }
      let data = directory ? Data() : try Data(contentsOf: file, options: .mappedIfSafe)
      guard data.count == size else { throw AgentFailure(message: "插件资源在读取期间发生变化。") }
      total += data.count
      digest.update(data: Data(relative.utf8)); digest.update(data: Data([0]))
      var encodedMode = mode.bigEndian, encodedSize = UInt64(data.count).bigEndian
      withUnsafeBytes(of: &encodedMode) { digest.update(data: Data($0)) }
      withUnsafeBytes(of: &encodedSize) { digest.update(data: Data($0)) }
      digest.update(data: data)
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
