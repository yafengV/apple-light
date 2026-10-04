import Foundation

struct GitHubPRActivityEvent: Identifiable, Equatable, Sendable {
  let id: String
  let kind: String
  let author: String
  let createdAt: String
  let text: String
  let url: String?
  var avatarURL: String? = nil
}

struct GitHubPRCommitGroup: Identifiable, Equatable, Sendable {
  var commits: [GitHubPRActivityEvent]
  var id: String { "commits:" + (commits.first?.id ?? "") }
  var createdAt: String { commits.last?.createdAt ?? "" }
}

enum GitHubPRActivityItem: Identifiable, Equatable, Sendable {
  case comment(GitHubPRComment), thread(GitHubPRReviewThread), event(GitHubPRActivityEvent)
  case commitGroup(GitHubPRCommitGroup)
  var id: String {
    switch self { case .comment(let x): "comment:" + x.id
    case .thread(let x): "thread:" + x.id
    case .event(let x): "event:" + x.id
    case .commitGroup(let x): x.id }
  }
  var createdAt: String {
    switch self { case .comment(let x): x.activityDate
    case .thread(let x): x.comments.first?.createdAt ?? ""
    case .event(let x): x.createdAt
    case .commitGroup(let x): x.createdAt }
  }
}

enum GitHubPRActivityDate {
  static func parse(_ value: String) -> Date? {
    (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
      ?? (try? Date.ISO8601FormatStyle().parse(value))
  }
}

extension GitHubPRDiscussionSnapshot {
  /// Count displayed conversation cards, rather than replies or timeline events.
  var overviewCommentCount: Int {
    activity.reduce(0) { count, item in
      switch item { case .comment, .thread: count + 1; case .event, .commitGroup: count }
    }
  }

  var activity: [GitHubPRActivityItem] {
    var items: [GitHubPRActivityItem] = []
    if let createdAt {
      items.append(.event(.init(id: "opened:" + requestURL, kind: "opened", author: author,
        createdAt: createdAt, text: "开启了此 PR", url: requestURL)))
    }
    items += events.filter { $0.kind == "PullRequestCommit" }.map(GitHubPRActivityItem.event)
    items += comments.filter { $0.kind == .issue && !$0.displayBody.isEmpty }
      .map(GitHubPRActivityItem.comment)
    for review in comments where review.kind == .review {
      let decision = review.reviewState?.uppercased()
      if decision == "APPROVED" || decision == "CHANGES_REQUESTED" {
        let kind = decision == "APPROVED" ? "approved" : "changes_requested"
        items.append(.event(.init(id: "review:" + review.id + ":" + kind, kind: kind, author: review.author,
          createdAt: review.activityDate, text: kind == "approved" ? "批准了这些更改" : "要求修改", url: review.url)))
      }
      if !review.displayBody.isEmpty { items.append(.comment(review)) }
    }
    items += threads.filter { $0.comments.first?.displayBody.isEmpty == false }
      .map(GitHubPRActivityItem.thread)
    if let mergedAt {
      items.append(.event(.init(id: "merged:" + requestURL, kind: "merged", author: mergedBy ?? "",
        createdAt: mergedAt, text: "合并了此 PR", url: requestURL)))
    }
    // Match the reference's stable numeric date ordering; invalid dates sort last.
    var dated: [(index: Int, item: GitHubPRActivityItem, date: Double)] = []
    for (index, item) in items.enumerated() {
      let date = GitHubPRActivityDate.parse(item.createdAt)?.timeIntervalSinceReferenceDate ?? Double.infinity
      dated.append((index: index, item: item, date: date))
    }
    let sorted = dated.sorted { $0.date == $1.date ? $0.index < $1.index : $0.date < $1.date }
    var result: [GitHubPRActivityItem] = []
    for entry in sorted {
      if case .event(let event) = entry.item, event.kind == "PullRequestCommit" {
        if let last = result.last, case .commitGroup(var group) = last {
          group.commits.append(event); result[result.count - 1] = .commitGroup(group)
        } else { result.append(.commitGroup(.init(commits: [event]))) }
      } else { result.append(entry.item) }
    }
    return result
  }
}
