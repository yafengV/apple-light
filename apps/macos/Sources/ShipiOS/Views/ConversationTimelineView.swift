import SwiftUI

struct ConversationTimelineView: View {
  @Bindable var store: WorkspaceStore
  @State private var childProjection = ChildElicitationProjection()
  @State private var scrolling = ConversationScrollState()
  @State private var scrollSnapshot = ConversationScrollSnapshot()
  @State private var readingTaskID: String?
  @State private var pendingReadingPosition: ConversationReadingPosition?
  @State private var revealedOnMount = false
  @State private var restoredReadingHistory = false
  @State private var mountedTexts: Set<ConversationTextID> = []
  @State private var pendingText: ConversationTextID?
  @State private var mountedOccurrences: Set<ConversationMatch.ID> = []
  @State private var pendingMatch: ConversationMatch.ID?
  @State private var railPositions: [String: CGRect] = [:]
  @State private var railViewportHeight: CGFloat = 0
  @State private var railFlash = ConversationRailFlash()
  private let railSpace = "main-conversation-rail-scroll"
  private var railItems: [ConversationRailItem] { store.conversationRailItems(for: store.conversationRuns) }
  private var railVisibleIDs: Set<String> {
    let visible = ConversationRailSelection.visibleIDs(positions: railPositions,
      orderedIDs: railItems.map(\.id), viewportHeight: railViewportHeight)
    return visible.isEmpty ? Set(railItems.suffix(1).map(\.id)) : visible
  }

  private var childRequests: [SubagentElicitationPresentation] {
    store.selectedTask.map { store.subagentElicitations(taskID: $0.id) } ?? []
  }
  private var childProjectionInput: ChildElicitationProjection.Input {
    .init(root: store.selectedTask?.codexThreadID, turns: store.conversationRuns.map(\.id), requests: childRequests.map(\.id))
  }
  private var projectedEntries: [ChildElicitationProjection.Entry] { childProjection.projected(childProjectionInput) }
  private var pendingReveal: ConversationRevealRequest? {
    guard let request = store.conversationReveal,
      !store.conversationReadingPositions.hasConsumedReveal(request.id),
      store.conversationRuns.contains(where: { $0.id == request.runID }) else { return nil }
    return request
  }

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
              if let runID = origin.runID { store.selection = runID }
            } label: {
              Label("分叉自 \(source.title)", systemImage: "arrow.triangle.branch")
                .lineLimit(2)
            }.buttonStyle(.plain).appFont(.caption).foregroundStyle(.secondary)
              .disabled(!store.canSelectTask(source))
          }
          ForEach(projectedEntries) { entry in
            switch entry {
            case .turn(let id):
              if let run = store.conversationRuns.first(where: { $0.id == id }) {
                ExecutionMessageView(store: store, run: run, railSpace: railSpace).id(run.id).padding(4)
                  .conversationRailPosition(run.id, in: railSpace)
              }
            case .child(let id, _):
              if let taskID = store.selectedTask?.id, let request = childRequests.first(where: { $0.id == id }) {
                ProjectedSubagentElicitationView(store: store, taskID: taskID, presentation: request).id(entry.id)
              }
            }
          }
          Color.clear.frame(height: 1).id("conversation-end")
        }.frame(maxWidth: 760).padding(.horizontal, 32).padding(.vertical, 28)
          .environment(\.conversationRailFlashID, railFlash.id)
          .frame(maxWidth: .infinity)
          .background {
            ConversationScrollObserver(snapshot: scrollSnapshot) { event in
              switch event {
              case .geometry(let metrics):
                if let saved = pendingReadingPosition {
                  guard let restored = scrollSnapshot.restore(offset: saved.metrics.offset) else { return }
                  pendingReadingPosition = nil
                  _ = scrolling.observe(restored)
                  rememberReadingPosition(restored)
                  return
                }
                if scrolling.observe(metrics) { scrollToLatest(reader) }
                rememberReadingPosition(metrics)
              case .began:
                pendingText = nil
                pendingMatch = nil
                scrolling.beginUserScroll()
              case .ended(let metrics):
                scrolling.endUserScroll(metrics)
                rememberReadingPosition(metrics)
              }
            }
          }
      }
      .coordinateSpace(name: railSpace)
      .background {
        GeometryReader { proxy in
          Color.clear.preference(key: ConversationRailViewportHeight.self,
            value: proxy.size.height)
        }
      }
      .defaultScrollAnchor(.top)
      .onAppear {
        readingTaskID = store.selectedTask?.id
        let saved = revealedOnMount || pendingReveal != nil ? nil
          : readingTaskID.flatMap { store.conversationReadingPositions.position(for: $0) }
        scrolling = ConversationScrollState(restoring: saved)
        restoredReadingHistory = saved?.followsLatest == false
        if let saved, restoredReadingHistory, saved.revisions != readingRevisions {
          _ = scrolling.contentChanged()
        }
        pendingReadingPosition = saved?.followsLatest == false ? saved : nil
      }
      .onDisappear {
        rememberReadingPosition(scrollSnapshot.metrics, preservingRevision: true)
        revealedOnMount = false
      }
      .overlay(alignment: .leading) {
        if railItems.count >= ConversationNavigationRail.minimumItems {
          ConversationRailOverlay(items: railItems,
            currentIDs: railVisibleIDs,
            onSelect: { id in
              pendingReadingPosition = nil
              pendingText = nil
              pendingMatch = nil
              scrolling.pauseFollowing()
              reader.scrollTo(id, anchor: .top)
              railFlash.flash(id, reduceMotion: store.appearance.shouldReduceMotion)
            }, onBookmark: { id, bookmarked in
              _ = store.setConversationBookmark(bookmarked, runID: id)
            }, visualizer: store.systemAudioVisualizer,
            audioEnabled: SystemAudioVisualizer.isSupported && store.destination == .workspace
              && store.audioVisualizerEnabled
              && !store.appearance.shouldReduceMotion,
            onAudioError: { store.error = $0 })
        }
      }
      .onPreferenceChange(ConversationRailPositions.self) { positions in
        railPositions = positions
      }
      .onPreferenceChange(ConversationRailViewportHeight.self) { railViewportHeight = $0 }
      .overlay(alignment: .bottom) {
        if !scrolling.isAtBottom {
          Button {
            pendingReadingPosition = nil
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
      .onChange(of: childProjectionInput, initial: true) { _, input in
        let old = Set(childProjection.entries.map(\.id))
        childProjection.update(input)
        if old.isEmpty && restoredReadingHistory { return }
        if childProjection.entries.contains(where: { !old.contains($0.id) }),
          scrolling.contentChanged(latest: scrollSnapshot.metrics), pendingReadingPosition == nil { scrollToLatest(reader) }
      }
      .onChange(of: revisions) { _, _ in
        if scrolling.contentChanged(latest: scrollSnapshot.metrics), pendingReadingPosition == nil { scrollToLatest(reader) }
      }
      .onChange(of: store.findRequest) { _, _ in findMatch(reader) }
      .onChange(of: store.conversationReveal, initial: true) { _, request in
        guard let request, pendingReveal?.id == request.id else { return }
        pendingReadingPosition = nil
        revealedOnMount = true
        store.conversationReadingPositions.consumeReveal(request.id)
        let owner = store.selectedTask?.id
        // Initial projection mounts on the next SwiftUI update. Keep the reveal
        // bounded to this request and owner rather than restoring cached history.
        let target = request.childRequestID.map { "child-elicitation:" + $0 } ?? request.runID
        DispatchQueue.main.async {
          guard store.selectedTask?.id == owner, store.conversationReveal?.id == request.id else { return }
          reader.scrollTo(target, anchor: .top)
        }
        if let child = request.childRequestID,
          projectedEntries.contains(where: { $0.id == "child-elicitation:" + child }) {
          pendingText = nil; pendingMatch = nil; scrolling.pauseFollowing()
          reader.scrollTo("child-elicitation:" + child, anchor: .top)
          return
        }
        guard store.conversationRuns.contains(where: { $0.id == request.runID }) else { return }
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
    pendingReadingPosition = nil
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
  private var readingRevisions: [ConversationReadingRevision] {
    readingTaskID.map { id in store.taskWindowRuns(id).map {
      .init(id: $0.id, updatedAt: $0.updatedAt, status: $0.status)
    } } ?? []
  }
  private func rememberReadingPosition(_ metrics: ConversationScrollMetrics?, preservingRevision: Bool = false) {
    guard pendingReadingPosition == nil, let readingTaskID else { return }
    let revision = preservingRevision
      ? store.conversationReadingPositions.position(for: readingTaskID)?.revisions ?? readingRevisions : readingRevisions
    store.conversationReadingPositions.remember(readingTaskID, metrics: metrics, state: scrolling, revisions: revision)
  }
}
