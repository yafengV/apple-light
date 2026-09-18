import Foundation

extension WorkspaceStore {
  func loadSSHHosts() async {
    guard !sshHostsLoading else { return }
    sshHostsLoading = true
    defer { sshHostsLoading = false }
    let config = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
    do {
      let aliases = try await Task.detached(priority: .userInitiated) {
        try SSHHostCatalog.load(configURL: config)
      }.value
      var resolved: [SSHHost] = []
      for host in aliases {
        resolved.append(await resolveSSHHost(host.alias))
      }
      sshHosts = resolved
      sshHostsLoaded = true
      sshHostsError = nil
    } catch {
      sshHostsError = error.localizedDescription
    }
  }

  func resolveSSHHost(_ alias: String) async -> SSHHost {
    await Task.detached(priority: .userInitiated) {
      let process = Process()
      let pipe = Pipe()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
      process.arguments = ["-G", "--", alias]
      process.standardOutput = pipe
      process.standardError = Pipe()
      do {
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
          return SSHHost(alias: alias, status: "无法解析")
        }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return SSHConfigParser.resolved(alias: alias, output: text)
      } catch { return SSHHost(alias: alias, status: error.localizedDescription) }
    }.value
  }

  func testSSHHost(_ alias: String) async {
    sshTestingHost = alias
    defer { sshTestingHost = nil }
    let result = await Task.detached(priority: .userInitiated) { () -> String in
      let process = Process()
      let output = Pipe()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
      process.arguments = [
        "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "ConnectionAttempts=1",
        "--", alias, "printf", "SHIPIOS_SSH_OK",
      ]
      process.standardOutput = output
      process.standardError = output
      do {
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        return process.terminationStatus == 0 && text.contains("SHIPIOS_SSH_OK")
          ? "连接成功" : (text.isEmpty ? "连接失败" : String(text.prefix(500)))
      } catch { return error.localizedDescription }
    }.value
    if let index = sshHosts.firstIndex(where: { $0.alias == alias }) { sshHosts[index].status = result }
  }
}
