import Foundation
import XCTest

enum AgentTestExecutable {
  static func url(file: StaticString = #filePath, line: UInt = #line) throws -> URL {
    let url: URL
    if let configured = ProcessInfo.processInfo.environment["SHIPIOS_TEST_AGENT"] {
      url = URL(fileURLWithPath: configured)
    } else {
      var repository = URL(fileURLWithPath: #filePath)
      for _ in 0..<5 { repository.deleteLastPathComponent() }
      url = repository.appendingPathComponent("target/debug/shipios-agent")
    }
    var directory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory),
      !directory.boolValue, FileManager.default.isExecutableFile(atPath: url.path) else {
      XCTFail("Build shipios-agent or set SHIPIOS_TEST_AGENT to an executable before integration tests.",
        file: file, line: line)
      throw CocoaError(.fileReadNoSuchFile)
    }
    return url
  }
}
