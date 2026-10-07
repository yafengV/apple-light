import SwiftUI

struct SubagentsPanelView: View {
  let agents: [CodexSubagent]
  var onSelect: ((CodexSubagent) -> Void)? = nil
  var liveEvents: (CodexSubagent) -> [JSONValue] = { _ in [] }
  @State private var showAllActive = false
  @State private var showAllDone = false
  private var overview: SubagentOverview { SubagentOverview(agents) }
  private var active: [CodexSubagent] { overview.active }
  private var done: [CodexSubagent] { overview.done }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        section("活动", rows: active, limit: showAllActive ? active.count : 4,
          showAll: { showAllActive = true }, empty: "没有活动的子任务")
        if !done.isEmpty {
          section("已完成", rows: done, limit: showAllDone ? done.count : 10,
            showAll: { showAllDone = true }, empty: "没有已完成的子任务")
        }
      }
      .padding(.horizontal, 12).padding(.vertical, 20)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityIdentifier("subagents-panel")
    .onChange(of: Set(agents.map(\.rootThreadID))) { _, _ in
      showAllActive = false; showAllDone = false
    }
  }

  private func section(_ title: String, rows: [CodexSubagent], limit: Int,
    showAll: @escaping () -> Void, empty: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Text(title); Text("· \(rows.count)")
        Spacer()
        let waiting = rows.filter { $0.overviewStatus == .waiting }.count
        if waiting > 0 { Text("\(waiting) 个等待中") }
      }.appFont(size: 14).foregroundStyle(.secondary).padding(.horizontal, 8)
      if rows.isEmpty { Text(empty).appFont(size: 14).foregroundStyle(.secondary).padding(.horizontal, 8) }
      VStack(spacing: 4) {
        ForEach(rows.prefix(limit)) { agent in
          if let onSelect {
            Button { onSelect(agent) } label: { row(agent) }.buttonStyle(.plain)
              .accessibilityLabel("打开子任务 \(agent.displayName)")
              .accessibilityIdentifier("subagent:\(agent.threadID)")
          } else { row(agent).accessibilityIdentifier("subagent:\(agent.threadID)") }
        }
        if rows.count > limit {
          Button("显示更多（\(rows.count - limit)）", action: showAll)
            .buttonStyle(.plain).appFont(size: 14).padding(.leading, 44)
            .padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
  }

  private func row(_ agent: CodexSubagent) -> some View {
    TimelineView(.periodic(from: .now, by: agent.overviewStatus == .done ? 60 : 1)) { context in
      let trailing = SubagentOverviewTime.trailing(for: agent, now: context.date)
      let preview = SubagentOverviewPreview.text(for: agent, liveEvents: liveEvents(agent))
      HStack(alignment: .top, spacing: 12) {
        SubagentAvatar(agent: agent)
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 12) {
            Text(agent.displayName).lineLimit(1); Spacer()
            ForEach(Array(trailing.enumerated()), id: \.offset) { _, label in
              Text(label).appFont(size: 12).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
            }
          }
          if let preview { Text(preview).foregroundStyle(.secondary).lineLimit(1) }
        }.appFont(size: 14)
      }.padding(8).frame(minHeight: 40).contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(([preview].compactMap { $0 } + trailing).joined(separator: "，"))
    }
  }
}

struct SubagentAvatar: View {
  let agent: CodexSubagent
  var body: some View {
    Image(systemName: "person.fill").font(.system(size: 12))
      .frame(width: 24, height: 24)
      .background(.secondary.opacity(0.12), in: Circle())
      .accessibilityHidden(true)
  }
}

struct SubagentsSummaryButton: View {
  let agents: [CodexSubagent]
  let open: () -> Void
  private var visible: [CodexSubagent] { SubagentOverview(agents).visible }
  private var working: [CodexSubagent] { visible.filter { $0.overviewStatus == .active } }
  private var waiting: [CodexSubagent] { visible.filter { $0.overviewStatus == .waiting } }
  private var done: [CodexSubagent] { visible.filter { $0.overviewStatus == .done } }
  var body: some View {
    if !visible.isEmpty {
      Button(action: open) {
        HStack(spacing: 8) {
          HStack(spacing: -5) {
            ForEach(Array((working.isEmpty ? (done.isEmpty ? visible : done) : working).prefix(4))) { SubagentAvatar(agent: $0) }
          }
          Text(working.isEmpty ? (done.isEmpty ? "\(visible.count) 个子任务" : "\(done.count) 个已完成") : "\(working.count) 个正在工作")
          Spacer()
          if !waiting.isEmpty { Text("\(waiting.count) 个等待中").foregroundStyle(.secondary) }
          if !working.isEmpty && !done.isEmpty { Text("\(done.count) 个已完成").foregroundStyle(.secondary) }
        }.appFont(size: 13)
      }.buttonStyle(.plain).accessibilityLabel("打开子任务")
        .accessibilityIdentifier("open-subagents")
    }
  }
}
