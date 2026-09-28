import AppKit
import Foundation

extension WorkspaceStore {
  func taskShareText(_ task: WorkspaceTask) -> String {
    var sections = ["# \(task.title)"]
    let knownRuns = Dictionary((library.localRuns + library.chatRuns + runs).map { ($0.id, $0) },
      uniquingKeysWith: { _, latest in latest })
    for id in task.runIDs {
      if let prompt = library.notes[id]?.trimmingCharacters(in: .whitespacesAndNewlines),
        !prompt.isEmpty
      {
        sections.append("## 用户\n\n\(prompt)")
      }
      guard let run = knownRuns[id] else { continue }
      let response =
        run.kind == "chat"
        ? run.result?["response"].text?.trimmingCharacters(in: .whitespacesAndNewlines)
        : run.displaySummary.trimmingCharacters(in: .whitespacesAndNewlines)
      if let response, !response.isEmpty {
        sections.append("## ShipiOS\n\n\(response)")
      }
    }
    if let link = ShipiOSDeepLink.task(task.id).url?.absoluteString {
      sections.append("在 ShipiOS 中打开：\(link)")
    }
    return sections.joined(separator: "\n\n") + "\n"
  }

  func copyTaskTranscript(_ task: WorkspaceTask) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(taskShareText(task), forType: .string)
  }
}
