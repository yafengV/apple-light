import AppKit
import Observation
import WebKit

@MainActor @Observable
final class BrowserSession {
  private struct ClosedTabState {
    let address: String
    let shouldNavigate: Bool
  }
  private(set) var tabs: [BrowserTab] = []
  private var closedTabs: [ClosedTabState] = []
  private(set) var selection: UUID?
  var addressFocus = UUID()
  var addressFocusTarget: UUID?
  var contentFocus = UUID()
  var contentFocusTarget: UUID?
  @ObservationIgnored weak var addressField: NSTextField?
  @ObservationIgnored var onEmpty: (() -> Void)?
  @ObservationIgnored var createChildTab: ((UUID, WKWebViewConfiguration?) -> BrowserTab?)?
  @ObservationIgnored var onTabOpened: ((UUID) -> Void)?
  @ObservationIgnored var onTabSelected: ((UUID) -> Void)?
  @ObservationIgnored var onTabClosed: ((UUID) -> Void)?
  @ObservationIgnored var onTabsReordered: (([UUID]) -> Void)?
  /// Content-tab owners choose the fallback within the closing tab's own pane.
  @ObservationIgnored var selectsAdjacentTabOnClose = true
  @ObservationIgnored var onVisit: ((URL, String) -> Void)?
  @ObservationIgnored var chooseDownloadDestination:
    ((URL, String, @escaping (BrowserDownloadDestination) -> Void) -> Void)?
  @ObservationIgnored var onDownloadEvent: ((BrowserDownloadEvent) -> Void)?
  @ObservationIgnored let dataStore: WKWebsiteDataStore
  @ObservationIgnored private var linkDownloadWorker: BrowserTab?
  var selected: BrowserTab? { tabs.first { $0.id == selection } }

  init(dataStore: WKWebsiteDataStore? = nil) {
    self.dataStore = dataStore ?? .nonPersistent()
  }

  @discardableResult func newTab(configuration: WKWebViewConfiguration? = nil, activate: Bool = true, id: UUID = UUID()) -> BrowserTab {
    if let existing = tabs.first(where: { $0.id == id }) { return existing }
    let configuration = configuration ?? makeConfiguration()
    let tab = BrowserTab(configuration: configuration, id: id)
    tab.openWindow = { [weak self] configuration in
      self?.newChildTab(from: id, configuration: configuration)
    }
    tab.openURLInNewTab = { [weak self] url in
      guard let tab = self?.newChildTab(from: id) else { return }
      tab.address = url.absoluteString
      tab.navigate()
    }
    tab.closeWindow = { [weak self, weak tab] in if let tab { self?.close(tab.id) } }
    tab.didVisit = { [weak self] url, title in self?.onVisit?(url, title) }
    configureDownloads(tab)
    tabs.append(tab)
    onTabOpened?(tab.id)
    if activate {
      selection = tab.id
      onTabSelected?(tab.id)
      focusAddress()
    }
    return tab
  }
  @discardableResult func newChildTab(from sourceID: UUID, configuration: WKWebViewConfiguration? = nil) -> BrowserTab? {
    guard tabs.contains(where: { $0.id == sourceID && !$0.closed }) else { return nil }
    if let createChildTab { return createChildTab(sourceID, configuration) }
    return newTab(configuration: configuration)
  }
  private func configureDownloads(_ tab: BrowserTab) {
    tab.chooseDownloadDestination = { [weak self] source, filename, completion in
      guard let self, let chooseDownloadDestination else {
        completion(.cancel)
        return
      }
      chooseDownloadDestination(source, filename, completion)
    }
    tab.didUpdateDownload = { [weak self] event in self?.onDownloadEvent?(event) }
  }
  @discardableResult func downloadLink(_ url: URL,
    chooseDestination: BrowserDownloadDestinationChooser? = nil) -> UUID? {
    guard BrowserAddress.permits(url) else { return nil }
    if linkDownloadWorker == nil {
      let worker = BrowserTab(configuration: makeConfiguration())
      configureDownloads(worker)
      linkDownloadWorker = worker
    }
    return linkDownloadWorker?.downloadURL(url, chooseDestination: chooseDestination)
  }
  private func makeConfiguration() -> WKWebViewConfiguration {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = dataStore
    return configuration
  }
  func ensureTab() { if tabs.isEmpty { newTab() } }
  func select(_ id: UUID, focus: Bool = true) {
    guard tabs.contains(where: { $0.id == id }) else { return }
    selection = id
    onTabSelected?(id)
    guard focus else { return }
    if selected?.committedURL == nil {
      focusAddress()
    } else {
      addressFocusTarget = nil
      contentFocusTarget = id
      contentFocus = UUID()
    }
  }
  func close(_ id: UUID) {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    let tab = tabs.remove(at: index)
    closedTabs.append(ClosedTabState(
      address: tab.committedURL?.absoluteString ?? tab.address,
      shouldNavigate: tab.committedURL != nil))
    if closedTabs.count > 20 { closedTabs.removeFirst(closedTabs.count - 20) }
    tab.close()
    onTabClosed?(id)
    if addressFocusTarget == id { addressFocusTarget = nil }
    if contentFocusTarget == id { contentFocusTarget = nil }
    if selection == id {
      if tabs.isEmpty { selection = nil }
      else if selectsAdjacentTabOnClose { select(tabs[min(index, tabs.count - 1)].id) }
      else { selection = nil }
    }
    if tabs.isEmpty { onEmpty?() }
  }
  var canReopenClosedTab: Bool { !closedTabs.isEmpty }
  @discardableResult func reopenClosedTab() -> BrowserTab? {
    guard let state = closedTabs.popLast() else { return nil }
    let tab = newTab()
    tab.address = state.address
    if state.shouldNavigate { tab.navigate() }
    return tab
  }
  func move(_ offset: Int) {
    guard !tabs.isEmpty else { return }
    let index = tabs.firstIndex { $0.id == selection } ?? 0
    select(tabs[(index + offset + tabs.count) % tabs.count].id)
  }
  @discardableResult func reorderTab(_ source: UUID, relativeTo target: UUID,
    after: Bool) -> Bool {
    guard source != target, let sourceIndex = tabs.firstIndex(where: { $0.id == source }),
      tabs.contains(where: { $0.id == target }) else { return false }
    let tab = tabs.remove(at: sourceIndex)
    guard let targetIndex = tabs.firstIndex(where: { $0.id == target }) else {
      tabs.insert(tab, at: min(sourceIndex, tabs.count))
      return false
    }
    tabs.insert(tab, at: targetIndex + (after ? 1 : 0))
    onTabsReordered?(tabs.map(\.id))
    return true
  }
  @discardableResult func reorderTab(_ source: UUID, horizontalTranslation: CGFloat,
    sourceWidth: CGFloat) -> Bool {
    guard let sourceIndex = tabs.firstIndex(where: { $0.id == source }), sourceWidth > 0,
      abs(horizontalTranslation) >= max(12, sourceWidth * 0.35) else { return false }
    let direction = horizontalTranslation > 0 ? 1 : -1
    let stepWidth = sourceWidth + 2
    let steps = max(1, Int((abs(horizontalTranslation) + stepWidth / 2) / stepWidth))
    let targetIndex = min(max(0, sourceIndex + direction * steps), tabs.count - 1)
    guard targetIndex != sourceIndex else { return false }
    return reorderTab(source, relativeTo: tabs[targetIndex].id, after: direction > 0)
  }
  func canCloseTabsToRight(of id: UUID) -> Bool {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
    return index < tabs.count - 1
  }
  func closeOtherTabs(keeping id: UUID) {
    guard tabs.contains(where: { $0.id == id }) else { return }
    selection = id
    for tab in tabs where tab.id != id { close(tab.id) }
  }
  func closeTabsToRight(of id: UUID) {
    guard let index = tabs.firstIndex(where: { $0.id == id }), index < tabs.count - 1 else {
      return
    }
    selection = id
    for tab in tabs[(index + 1)...].reversed() { close(tab.id) }
  }
  func focusAddress() {
    ensureTab()
    if let selection { focusAddress(tabID: selection) }
  }
  func focusAddress(tabID: UUID) {
    guard tabs.contains(where: { $0.id == tabID }) else { return }
    contentFocusTarget = nil
    addressFocusTarget = tabID
    addressFocus = UUID()
  }
  func focusContent(_ id: UUID) {
    guard tabs.contains(where: { $0.id == id }) else { return }
    if selection != id { select(id) }
    addressFocusTarget = nil
    contentFocusTarget = id
    contentFocus = UUID()
  }
  var hasNativeFocus: Bool { hasNativeFocus(tabID: selection) }
  func hasNativeFocus(tabID: UUID?) -> Bool {
    guard let tabID, let tab = tabs.first(where: { $0.id == tabID }),
      let window = NSApp?.keyWindow, window.attachedSheet == nil,
      tab.view.window === window, let responder = window.firstResponder else { return false }
    if let field = addressField, field.window === window,
      responder === field || responder === field.currentEditor() { return true }
    if let view = responder as? NSView,
      view === tab.view || view.isDescendant(of: tab.view) { return true }
    return false
  }
  func hasEditableFocus(tabID: UUID?, in window: NSWindow? = NSApp?.keyWindow) -> Bool {
    guard let tabID, let tab = tabs.first(where: { $0.id == tabID }),
      let window, tab.view.window === window,
      let responder = window.firstResponder else { return false }
    if let field = addressField, field.window === window,
      responder === field || responder === field.currentEditor() { return true }
    return tab.pageEditingText && (responder === tab.view
      || (responder as? NSView)?.isDescendant(of: tab.view) == true)
  }
  var hasEditableFocus: Bool { hasEditableFocus(tabID: selection) }
  func copyURL(tabID: UUID? = nil, to pasteboard: NSPasteboard = .general) {
    let tab: BrowserTab?
    if let tabID { tab = tabs.first { $0.id == tabID } } else { tab = selected }
    guard let url = tab?.committedURL else { return }
    pasteboard.clearContents(); pasteboard.setString(url.absoluteString, forType: .string)
  }
  func shutdown() {
    linkDownloadWorker?.close(); linkDownloadWorker = nil
    tabs.forEach { $0.close() }; tabs = []; selection = nil
    addressFocusTarget = nil; contentFocusTarget = nil
  }
  func cancelDownload(_ id: UUID) {
    for tab in tabs where tab.cancelDownload(id) { return }
    _ = linkDownloadWorker?.cancelDownload(id)
  }
  func clearWebsiteData() async {
    let types = WKWebsiteDataStore.allWebsiteDataTypes()
    await withCheckedContinuation { continuation in
      dataStore.removeData(ofTypes: types, modifiedSince: .distantPast) {
        continuation.resume()
      }
    }
  }
}
