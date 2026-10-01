import Foundation

struct TaskSummaryArtifact: Identifiable, Equatable {
  let runID: String
  let title: String
  let directory: URL
  var id: String { runID }

  var outputs: [TaskSummaryOutputFile] {
    [
      .init(runID: runID, directory: directory, name: "stdout.log", title: "标准输出", kind: .log),
      .init(runID: runID, directory: directory, name: "stderr.log", title: "错误输出", kind: .log),
      .init(runID: runID, directory: directory, name: "build.xcresult", title: "构建结果", kind: .bundle),
    ].filter(\.isAvailable)
  }
}

struct TaskSummaryOutputFile: Identifiable, Equatable, Sendable {
  enum Kind: Equatable, Sendable { case log, bundle }
  let runID: String
  let directory: URL
  let name: String
  let title: String
  let kind: Kind
  var id: String { runID + ":" + name }
  var url: URL { directory.appendingPathComponent(name, isDirectory: kind == .bundle) }

  var isAvailable: Bool {
    let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
    let resolvedFile = url.resolvingSymlinksInPath().standardizedFileURL
    guard resolvedFile.deletingLastPathComponent() == resolvedDirectory else { return false }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: resolvedFile.path, isDirectory: &isDirectory) else { return false }
    return isDirectory.boolValue == (kind == .bundle)
  }

  func readLog(maxBytes: Int = 1_048_576) throws -> (text: String, truncated: Bool) {
    guard kind == .log, isAvailable else {
      throw AgentFailure(message: "输出文件已移除或不可读取。")
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
    let truncated = data.count > maxBytes
    return (String(decoding: data.prefix(maxBytes), as: UTF8.self), truncated)
  }
}

extension Collection where Element == AgentRun {
  /// External resources produced or updated by successful MCP calls, including ones also read.
  var summaryExternalArtifacts: [TaskExternalSource] {
    var resources: [TaskExternalSource] = []
    for run in self {
      for execution in run.toolExecutions where execution.status == .succeeded {
        for resource in execution.mcpResourceActivities
          ?? MCPResourceActivity.restored(from: execution.output) ?? [] {
          guard let key = CodexWebSource.sourceKey(resource.source.url) else { continue }
          if let index = resources.firstIndex(where: { $0.id == key }) {
            for activity in resource.activities {
              resources[index].merge(resource.source, activity: activity, preferTitle: true)
            }
          } else {
            resources.append(TaskExternalSource(resource: resource.source,
              activities: resource.activities))
          }
        }
      }
    }
    return resources.filter { $0.activities.contains(.created) || $0.activities.contains(.updated) }
  }

  var summaryArtifacts: [TaskSummaryArtifact] {
    compactMap { run in
      guard run.kind != "chat", let path = run.result?["artifactDirectory"].text,
        path.hasPrefix("/") else { return nil }
      return TaskSummaryArtifact(runID: run.id, title: run.title,
        directory: URL(fileURLWithPath: path, isDirectory: true))
    }
  }
}
