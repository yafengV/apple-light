import Foundation
import Observation

enum EnvironmentPage: Equatable {
  case projects, overview, editor
}

@MainActor @Observable final class EnvironmentSettingsNavigation {
  private(set) var page = EnvironmentPage.projects

  @ObservationIgnored private var operation = UUID()

  struct Ticket {
    fileprivate let operation: UUID
    fileprivate let route: UUID
    fileprivate let session: UUID
  }

  func show(_ page: EnvironmentPage) { invalidate(); self.page = page }
  func invalidate() { operation = UUID() }

  func begin(in store: WorkspaceStore) -> Ticket? {
    guard store.destination == .settings, store.settingsPage == .environments, !Task.isCancelled else { return nil }
    invalidate()
    return Ticket(operation: operation, route: store.environmentSettingsNavigationRevision, session: store.session)
  }

  func isCurrent(_ ticket: Ticket, in store: WorkspaceStore) -> Bool {
    ticket.operation == operation && ticket.route == store.environmentSettingsNavigationRevision
      && ticket.session == store.session && store.destination == .settings
      && store.settingsPage == .environments && !Task.isCancelled
  }

  func openProject(_ path: String, selectionID: String? = nil, createNew: Bool = false,
    showEditor: Bool = false, environment: EnvironmentSettingsSession, store: WorkspaceStore) async {
    guard let ticket = begin(in: store) else { return }
    if environment.hasUnsavedChanges,
      environment.projectPath != path || createNew || selectionID != nil {
      environment.status = "当前环境有未保存的修改，请先保存或放弃。"
      show(.editor)
      return
    }
    if environment.projectPath != path || !environment.connected {
      await environment.open(path, title: store.library.projectTitle(path), executable: store.executable)
    }
    guard isCurrent(ticket, in: store) else { return }
    guard environment.connected, environment.projectPath == path else { show(.projects); return }
    if createNew { environment.create() }
    else if let selectionID { await environment.select(selectionID) }
    guard isCurrent(ticket, in: store), environment.connected, environment.projectPath == path else { return }
    let needsEditor = showEditor || createNew || selectionID.flatMap { selected in
      environment.files.first(where: { $0.id == selected })?.error
    } != nil
    show(needsEditor ? .editor : .overview)
  }

  func select(_ entry: LocalEnvironmentEntry, environment: EnvironmentSettingsSession,
    store: WorkspaceStore) async {
    guard let ticket = begin(in: store) else { return }
    await environment.select(entry.id)
    guard isCurrent(ticket, in: store) else { return }
    if environment.fileName == entry.id { show(entry.error == nil ? .overview : .editor) }
  }

  func save(returnToOverview: Bool, environment: EnvironmentSettingsSession,
    store: WorkspaceStore, synchronize: (String, String, Bool) async -> Bool) async {
    guard page == .editor, let ticket = begin(in: store) else { return }
    guard await environment.saveFromSettings(synchronize: synchronize) else { return }
    if returnToOverview && isCurrent(ticket, in: store) && page == .editor {
      show(.overview)
    }
  }

  func discard(environment: EnvironmentSettingsSession, store: WorkspaceStore) async {
    guard page == .editor, let ticket = begin(in: store) else { return }
    guard await environment.reloadFromSettings() else { return }
    guard isCurrent(ticket, in: store), page == .editor else { return }
    show(.overview)
  }
}
