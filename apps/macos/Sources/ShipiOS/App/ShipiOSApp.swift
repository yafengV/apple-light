import AppKit
import SwiftUI
import UserNotifications
import WebKit

@main
struct ShipiOSApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @State private var store = WorkspaceStore(browserDataStore:
    CommandLine.arguments.contains("--data-root") ? nil : WKWebsiteDataStore.default())

  var body: some Scene {
    Window("ShipiOS", id: "main") {
      AppContentView(store: store)
        .frame(minWidth: 960, minHeight: 600)
        .environment(\.appAppearance, store.appearance)
        .transaction { $0.disablesAnimations = store.appearance.shouldReduceMotion }
        .font(store.appearance.font(size: 13))
        .foregroundStyle(store.appearance.foregroundColor)
        .tint(store.appearance.accentColor)
        .background(store.appearance.backgroundColor)
        .preferredColorScheme(store.appearance.colorScheme)
        .task {
          delegate.store = store
          await store.restore()
          await delegate.finishRestoration()
        }
    }
    .defaultSize(width: 1120, height: 780)
    .windowResizability(.contentMinSize)
    .commands { WorkspaceCommands(store: store) }
    WindowGroup("任务", for: TaskWindowRoute.self) { route in
      TaskWindowSceneView(store: store, route: route)
        .environment(\.appAppearance, store.appearance)
        .transaction { $0.disablesAnimations = store.appearance.shouldReduceMotion }
        .font(store.appearance.font(size: 13))
        .foregroundStyle(store.appearance.foregroundColor)
        .tint(store.appearance.accentColor)
        .background(store.appearance.backgroundColor)
        .preferredColorScheme(store.appearance.colorScheme)
    }
    .defaultSize(width: 760, height: 720)
    .windowResizability(.contentMinSize)
    WindowGroup("标签页", for: WorkspaceTabWindowRoute.self) { route in
      WorkspaceTabWindowSceneView(store: store, route: route)
        .environment(\.appAppearance, store.appearance)
        .transaction { $0.disablesAnimations = store.appearance.shouldReduceMotion }
        .font(store.appearance.font(size: 13))
        .foregroundStyle(store.appearance.foregroundColor)
        .tint(store.appearance.accentColor)
        .background(store.appearance.backgroundColor)
        .preferredColorScheme(store.appearance.colorScheme)
    }
    .defaultSize(width: 860, height: 680)
    .windowResizability(.contentMinSize)
    MenuBarExtra(
      "ShipiOS", systemImage: "shippingbox.fill",
      isInserted: Binding(
        get: { store.showInMenuBar },
        set: { store.showInMenuBar = $0 })
    ) {
      ShipiOSMenuBarView(store: store)
    }
    .menuBarExtraStyle(.menu)
  }
}

private struct ShipiOSMenuBarView: View {
  @Bindable var store: WorkspaceStore
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button("显示 ShipiOS") { showMainWindow() }
    Button("新建任务") {
      store.newTask()
      showMainWindow()
    }
    Button("弹出窗口") { store.popoutWindowHandler?() }
    Divider()
    Button("退出 ShipiOS") { NSApp.terminate(nil) }
  }

  private func showMainWindow() {
    openWindow(id: "main")
    NSApp.activate(ignoringOtherApps: true)
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  var store: WorkspaceStore?
  private var petPanelController: PetPanelController?
  private var petGlobalHotKey: AppGlobalHotKey?
  private var popoutGlobalHotKey: AppGlobalHotKey?
  private var appshotModifierMonitor: AppshotModifierMonitor?
  private var mainWindowFocusObserver: NSObjectProtocol?
  private var lastMainWindowFocus: Date?
  private var popoutWindowController: PopoutWindowController?
  private let pointerCursorController = PointerCursorController()
  private var quitting = false
  private var ready = false
  private var automationPoller: Task<Void, Never>?
  private var skillPoller: Task<Void, Never>?
  private var pendingNotification: NotificationDestination?
  private var pendingDeepLinks: [ShipiOSDeepLink] = []
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    UNUserNotificationCenter.current().delegate = self
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    !(store?.showInMenuBar ?? true)
  }
  func application(_ application: NSApplication, open urls: [URL]) {
    let links = urls.compactMap(ShipiOSDeepLink.init(url:))
    guard !links.isEmpty else { return }
    pendingDeepLinks.append(contentsOf: links)
    application.activate(ignoringOtherApps: true)
    Task { await openPendingDeepLinks() }
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !quitting else { return .terminateLater }
    quitting = true
    stopAutomationPolling()
    stopSkillMonitoring()
    appshotModifierMonitor = nil
    if let mainWindowFocusObserver {
      NotificationCenter.default.removeObserver(mainWindowFocusObserver)
      self.mainWindowFocusObserver = nil
    }
    Task {
      await store?.shutdown()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  func finishRestoration() async {
    if let store {
      let controller = PetPanelController(store: store)
      petPanelController = controller
      store.petPanelHandler = { [weak controller] preferences in controller?.apply(preferences) }
      controller.apply(store.petPreferences)
      let hotKey = AppGlobalHotKey(id: 1, title: "宠物") { [weak store] in
        guard let store, store.shortcutCaptureCount == 0 else { return }
        store.togglePet()
      }
      petGlobalHotKey = hotKey
      let popoutController = PopoutWindowController(store: store)
      popoutWindowController = popoutController
      store.popoutWindowHandler = { [weak popoutController] in popoutController?.openHome() }
      store.popoutWindowToggleHandler = { [weak popoutController] in popoutController?.toggle() }
      let popoutHotKey = AppGlobalHotKey(id: 2, title: "弹出窗口") { [weak popoutController, weak store] in
        guard store?.shortcutCaptureCount == 0 else { return }
        popoutController?.toggle()
      }
      popoutGlobalHotKey = popoutHotKey
      mainWindowFocusObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
      ) { [weak self] notification in
        guard let window = notification.object as? NSWindow,
          window.identifier?.rawValue == "main" else { return }
        Task { @MainActor [weak self] in self?.lastMainWindowFocus = Date() }
      }
      if NSApp.keyWindow?.identifier?.rawValue == "main" { lastMainWindowFocus = Date() }
      appshotModifierMonitor = AppshotModifierMonitor(
        hotkey: { [weak store] in store?.appshotHotkey ?? .none },
        onTrigger: { [weak self] in self?.captureAppshotFromShortcut() })
      let refreshHotKey = { [weak hotKey, weak store] in
        guard let hotKey, let store else { return }
        do { try hotKey.register(store.shortcuts.binding("pet")) }
        catch { store.petError = error.localizedDescription }
      }
      let refreshPopoutHotKey = { [weak popoutHotKey, weak store] in
        guard let popoutHotKey, let store else { return }
        do {
          try popoutHotKey.register(store.shortcuts.binding("popout"))
          store.popoutHotkeyError = nil
        } catch { store.popoutHotkeyError = error.localizedDescription }
      }
      store.shortcuts.didChange = { id in
        if id == "pet" || id == "*" { refreshHotKey() }
        if id == "popout" || id == "*" { refreshPopoutHotKey() }
      }
      refreshHotKey()
      refreshPopoutHotKey()
      store.appearanceHandler = { [weak pointerCursorController] appearance in
        pointerCursorController?.apply(appearance.usePointerCursors)
      }
      pointerCursorController.apply(store.appearance.usePointerCursors)
      startAutomationPolling()
      startSkillMonitoring()
    }
    ready = true
    await openPendingNotification()
    await openPendingDeepLinks()
  }

  private func captureAppshotFromShortcut() {
    guard let store, store.appshotHotkey != .none, store.shortcutCaptureCount == 0,
      !store.shuttingDown, !store.hasSettingsConfirmation else { return }
    let target = store.appshotCapture.availableTarget()
    let currentChat = store.selectedTask != nil
    let recentlyFocused = lastMainWindowFocus.map { Date().timeIntervalSince($0) < 60 } ?? false
    let startNew = store.appshotDestination.shouldStartNewChat(
      hasCurrentChat: currentChat, focusedRecently: recentlyFocused,
      canAcceptShortcut: store.destination == .workspace && store.action == .chat)
    if startNew && store.busy { return }
    Task { @MainActor [weak store] in
      guard let store else { return }
      if startNew { await store.newChat() }
      let owner = NSApp.windows.first { $0.identifier?.rawValue == "main" }
      await store.captureAppshot(draft: store.draftKey, target: target,
        onScreenshot: { [weak store] in
          guard let store else { return }
          if store.destination != .workspace { store.returnToWorkspace() }
          store.showMainWindowHandler?()
          if store.appshotSoundEnabled { NSSound.beep() }
        }, ownerWindow: owner)
    }
  }

  func startAutomationPolling(every interval: Duration = .seconds(30)) {
    guard automationPoller == nil, let store else { return }
    automationPoller = Task { [weak store] in
      while !Task.isCancelled {
        guard let store else { break }
        // A run can wait for tool approval. Keep polling other due schedules.
        Task { await store.runDueAutomations() }
        try? await Task.sleep(for: interval)
      }
    }
  }

  func stopAutomationPolling() {
    automationPoller?.cancel()
    automationPoller = nil
  }

  func startSkillMonitoring(every interval: Duration = .seconds(2)) {
    guard skillPoller == nil, let store else { return }
    skillPoller = Task { [weak store] in
      while !Task.isCancelled {
        guard let store, !store.shuttingDown else { break }
        await store.refreshSkillsIfChanged()
        try? await Task.sleep(for: interval)
      }
    }
  }

  func stopSkillMonitoring() {
    skillPoller?.cancel()
    skillPoller = nil
  }

  private func openPendingDeepLinks() async {
    guard ready, let store else { return }
    while !pendingDeepLinks.isEmpty {
      let link = pendingDeepLinks.removeFirst()
      await store.openDeepLink(link)
    }
  }

  private func openPendingNotification() async {
    guard ready, let store, let target = pendingNotification else { return }
    pendingNotification = nil
    _ = await store.openNotification(target)
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { completionHandler(); return }
    let target = NotificationDestination(userInfo: response.notification.request.content.userInfo)
    Task { @MainActor in
      self.pendingNotification = target
      NSApp.activate(ignoringOtherApps: true)
      await self.openPendingNotification()
      completionHandler()
    }
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    let target = NotificationDestination(userInfo: notification.request.content.userInfo)
    Task { @MainActor in
      let show = target == nil || (target?.dataRoot == self.store?.dataRoot.path
        && self.store?.notificationPreferences.permits(appIsActive: NSApp.isActive) == true)
      completionHandler(show ? [.banner, .list, .sound] : [])
    }
  }
}
