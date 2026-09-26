import Foundation

struct TaskSummaryArtifact: Identifiable, Equatable {
  let runID: String
  let title: String
  let directory: URL
  var id: String { runID }
}

extension Collection where Element == AgentRun {
  var summaryArtifacts: [TaskSummaryArtifact] {
    compactMap { run in
      guard run.kind != "chat", let path = run.result?["artifactDirectory"].text,
        path.hasPrefix("/") else { return nil }
      return TaskSummaryArtifact(runID: run.id, title: run.title,
        directory: URL(fileURLWithPath: path, isDirectory: true))
    }
  }
}
