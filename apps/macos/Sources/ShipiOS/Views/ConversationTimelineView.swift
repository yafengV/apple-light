import SwiftUI

struct ConversationTimelineView: View {
  @Bindable var store: WorkspaceStore
  @State private var scrolling = ConversationScrollState()
  @State private var mountedTexts: Set<ConversationTextID> = []
  @State private var pendingText: ConversationTextID?
  @State private var mountedOccurrences: Set<ConversationMatch.ID> = []
  @State private var pendingMatch: ConversationMatch.ID?

  private struct Revision: Equatable {
    let id: String
    let updatedAt: Double
    let status: String
  }
  private var revisions: [Revision] {
    store.conversationRuns.map { Revision(id: $0.id, updatedAt: $0.updatedAt, status: $0.status) }
  }
  private struct FindRevision: Equatable {
    let query: String
    let runs: [Revision]
  }

  var body: some View {
    ScrollViewReader { reader in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 32) {
          if let origin = store.selectedTask?.forkOrigin,
            let source = store.library.tasks.first(where: { $0.id == origin.taskID })
          {
            Button {
              store.selectTask(source)
              store.selection = origin.runID
            } label: {
              Label("分叉自 \(source.title)", systemImage: "arrow.triangle.branch")
                .lineLimit(2)
            }.buttonStyle(.plain).appFont(.caption).foregroundStyle(.secondary)
              .disabled(!store.canSelectTask(source))
          }
          ForEach(store.conversationRuns) { run in
            ExecutionMessageView(store: store, run: run).id(run.id).padding(4)
          }
          Color.clear.frame(height: 1).id("conversation-end")
        }.frame(maxWidth: 760).padding(.horizontal, 32).padding(.vertical, 28)
          .frame(maxWidth: .infinity)
          .background {
            ConversationScrollObserver { event in
              switch event {
              case .geometry(let metrics):
                if scrolling.observe(metrics) { scrollToLatest(reader) }
              case .began:
                pendingText = nil
                pendingMatch = nil
                scrolling.beginUserScroll()
              case .ended(let metrics): scrolling.endUserScroll(metrics)
              }
            }
          }
      }
      .defaultScrollAnchor(.top)
      .overlay(alignment: .bottom) {
        if !scrolling.isAtBottom {
          Button {
            pendingText = nil
            pendingMatch = nil
            scrolling.requestLatest()
            scrollToLatest(reader)
          } label: {
            Image(systemName: "arrow.down").appFont(size: 13, weight: .semibold)
              .frame(width: 32, height: 32)
              .background(.regularMaterial, in: Circle())
              .overlay(Circle().strokeBorder(.primary.opacity(0.12)))
              .overlay(alignment: .topTrailing) {
                if scrolling.hasNewContent {
                  Circle().fill(.tint).frame(width: 7, height: 7)
                }
              }
          }.buttonStyle(.plain).padding(.bottom, 12)
            .help(scrolling.hasNewContent ? "有新内容，返回底部" : "返回底部")
            .accessibilityLabel(scrolling.hasNewContent ? "有新内容，返回底部" : "返回底部")
        }
      }
      .onChange(of: revisions) { _, _ in
        if scrolling.contentChanged() { scrollToLatest(reader) }
      }
      .onChange(of: store.findRequest) { _, _ in findMatch(reader) }
      .onChange(of: store.conversationReveal, initial: true) { _, request in
        guard let request, store.conversationRuns.contains(where: { $0.id == request.runID }) else { return }
        pendingText = nil
        pendingMatch = nil
        scrolling.pauseFollowing()
        reader.scrollTo(request.runID, anchor: .top)
      }
      .onPreferenceChange(ConversationTextAnchors.self) { anchors in
        mountedTexts = anchors
        if let pendingText, anchors.contains(pendingText) {
          reader.scrollTo(pendingText, anchor: .center)
          self.pendingText = nil
        }
      }
      .onChange(of: store.showingFind) { _, visible in
        if !visible {
          pendingText = nil
          pendingMatch = nil
          scrolling.endNavigation()
        }
      }
      .onChange(of: store.findText) { _, query in
        pendingText = nil
        pendingMatch = nil
        if store.showingFind && !query.isEmpty { scrolling.pauseFollowing() }
      }
      .onPreferenceChange(ConversationOccurrenceAnchors.self) { anchors in
        mountedOccurrences = anchors
        if let pendingMatch, anchors.contains(pendingMatch) {
          reader.scrollTo(pendingMatch, anchor: .center)
          self.pendingMatch = nil
          pendingText = nil
        }
      }
      .task(id: FindRevision(query: store.showingFind ? store.findText : "", runs: revisions)) {
        guard store.showingFind else { return }
        await store.refreshFindMatches()
      }
    }
    .environment(
      \.conversationFind,
      ConversationFindContext(
        query: store.showingFind ? store.findText : "", active: store.activeFindMatch))
  }

  private func findMatch(_ reader: ScrollViewProxy) {
    guard let match = store.activeFindMatch else { return }
    scrolling.pauseFollowing()
    if mountedOccurrences.contains(match.id) {
      pendingText = nil
      pendingMatch = nil
      reader.scrollTo(match.id, anchor: .center)
      return
    }
    pendingMatch = match.id
    if mountedTexts.contains(match.textID) {
      pendingText = nil
      reader.scrollTo(match.textID, anchor: .center)
    } else {
      pendingText = match.textID
      reader.scrollTo(match.textID.run, anchor: .top)
    }
  }
  private func scrollToLatest(_ reader: ScrollViewProxy) {
    reader.scrollTo("conversation-end", anchor: .bottom)
  }
}
