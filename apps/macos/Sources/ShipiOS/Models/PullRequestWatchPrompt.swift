import Foundation

enum PullRequestWatchPrompt {
  static func make(_ request: GitHubPullRequest, preferences: GitPreferences) -> String? {
    guard let url = request.validatedURL else { return nil }
    var text = """
      Watch and fix pull request #\(request.number).
      Pull request URL: \(url.absoluteString)
      Branch: \(request.headRefName) -> \(request.baseRefName)

      This automation checks again every 10 minutes. Re-read the live pull request, head commit, mergeability, checks, logs and annotations on every run. Fix only failures caused by this pull request or conflicts with its base branch. Leave unrelated failures, infrastructure outages and flakes alone unless the custom instructions explicitly authorize broader repairs. If checks are pending, finish this turn without sleeping; the next scheduled run will check again.

      Never change, switch, clean, reset or commit from the configured checkout. Make all code changes in this run's isolated worktree. Before making a change, fetch the pull request's current head branch into that worktree; do not assume the worktree starts at the PR head. Keep the fix minimal, run relevant verification, and push only to the PR branch after rechecking its latest head commit. Do not bypass branch protections. Do not remove a worktree containing uncommitted changes.

      If the pull request is merged or closed, pause this heartbeat with shipios_pause_automation before your final response. If credentials, access or a user decision block progress, report the exact blocker, ask one concise question in this thread, and pause this heartbeat with shipios_pause_automation. Do not create or suggest another automation.
      """
    if preferences.autoMergeWatchedPullRequests {
      text += "\nOnce all required checks pass and the PR is mergeable, merge it using the repository's allowed workflow. Recheck the head commit immediately before merging and require GitHub's matching-head-commit guard. If merging fails, diagnose it and continue on later scheduled runs until merged or closed.\n"
    } else {
      text += "\nDo not merge or enable automatic merge unless the custom instructions explicitly request it. When checks pass and the PR is conflict-free, pause this heartbeat with shipios_pause_automation before your final response unless custom instructions explicitly require continuing.\n"
    }
    let instructions = preferences.pullRequestWatchInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
    if !instructions.isEmpty { text += "\nAdditional watch instructions:\n\(instructions)\n" }
    return text
  }
}
