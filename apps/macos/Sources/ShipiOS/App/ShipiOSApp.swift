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
    if let target = store.dictation.target, target.hasPrefix("global-dictation:") {
      Button("结束全局听写") { store.dictation.stop(target: target) }
    }
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
  private var globalDictationToggleHotKey: AppGlobalHotKey?
  private var globalDictationHoldHotKey: AppGlobalHotKey?
  private var registeredGlobalToggleHotkey: ShortcutBinding?
  private var registeredGlobalHoldHotkey: ShortcutBinding?
  private var globalDictationState = GlobalDictationToggleState()
  private var globalDictationHoldState = GlobalDictationHoldState()
  private enum GlobalDictationMode { case hold, toggle }
  private var appshotModifierMonitor: AppshotModifierMonitor?
  private var appshotShortcutPending = false
  private var appshotWindowFocusObserver: NSObjectProtocol?
  private weak var lastAppshotWindow: NSWindow?
  private var lastAppshotWindowFocus: Date?
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
    store?.appshotHotkeyChangeHandler = nil
    store?.globalDictationHotkeyChangeHandler = nil
    if let appshotWindowFocusObserver {
      NotificationCenter.default.removeObserver(appshotWindowFocusObserver)
      self.appshotWindowFocusObserver = nil
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
      let dictationHotKey = AppGlobalHotKey(id: 3, title: "切换听写") { [weak self] in
        self?.toggleGlobalDictation()
      }
      globalDictationToggleHotKey = dictationHotKey
      let holdDictationHotKey = AppGlobalHotKey(id: 4, title: "按住听写",
        onRelease: { [weak self] in self?.releaseHoldGlobalDictation() }) { [weak self] in
        self?.pressHoldGlobalDictation()
      }
      globalDictationHoldHotKey = holdDictationHotKey
      store.globalDictationHotkeyChangeHandler = { [weak self] in
        self?.refreshGlobalDictationHotkey()
      }
      appshotWindowFocusObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
      ) { [weak self] notification in
        guard let window = notification.object as? NSWindow else { return }
        Task { @MainActor [weak self] in
          guard let self, NSApp.windows.contains(where: { $0 === window }) else { return }
          self.lastAppshotWindow = window
          self.lastAppshotWindowFocus = Date()
        }
      }
      if let window = NSApp.keyWindow {
        lastAppshotWindow = window
        lastAppshotWindowFocus = Date()
      }
      appshotModifierMonitor = AppshotModifierMonitor(
        hotkey: { [weak store] in store?.appshotHotkey ?? .none },
        onTrigger: { [weak self] in self?.captureAppshotFromShortcut() },
        onRegistrationState: { [weak store] requested, registered in
          let error = requested && !registered ? "无法注册应用快照全局快捷键。切换应用后将自动重试。" : nil
          if store?.appshotHotkeyError != error { store?.appshotHotkeyError = error }
        })
      store.appshotHotkeyChangeHandler = { [weak self] in
        self?.appshotModifierMonitor?.refreshGlobalMonitor()
      }
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
      refreshGlobalDictationHotkey()
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

  private func refreshGlobalDictationHotkey() {
    guard let store, let globalDictationToggleHotKey, let globalDictationHoldHotKey else { return }
    var errors: [String] = []
    let toggle = store.voicePreferences.globalToggleHotkey
    if toggle != registeredGlobalToggleHotkey {
      do {
        try globalDictationToggleHotKey.register(toggle)
        registeredGlobalToggleHotkey = toggle
      } catch {
        registeredGlobalToggleHotkey = nil
        errors.append(error.localizedDescription)
      }
    }
    let hold = store.voicePreferences.globalHoldHotkey
    if hold != registeredGlobalHoldHotkey {
      do {
        try globalDictationHoldHotKey.register(hold)
        registeredGlobalHoldHotkey = hold
      } catch {
        registeredGlobalHoldHotkey = nil
        errors.append(error.localizedDescription)
      }
    }
    store.globalDictationHotkeyError = errors.isEmpty ? nil : errors.joined(separator: "\n")
  }

  private func toggleGlobalDictation() {
    guard let store, !quitting, store.shortcutCaptureCount == 0 else { return }
    guard globalDictationHoldState.token == nil else { return }
    let decision = globalDictationState.press(activeTarget: store.dictation.target,
      newToken: "global-dictation:" + UUID().uuidString)
    switch decision {
    case .stop(let token):
      store.dictation.stop(target: token)
      return
    case .cancelPending:
      return
    case .start(let token):
      beginGlobalDictation(token: token, mode: .toggle, store: store)
    }
  }

  private func pressHoldGlobalDictation() {
    guard let store, !quitting, store.shortcutCaptureCount == 0 else { return }
    if let toggleToken = globalDictationState.token,
      globalDictationState.starting || store.dictation.target == toggleToken { return }
    guard let token = globalDictationHoldState.press(
      newToken: "global-dictation:" + UUID().uuidString) else { return }
    beginGlobalDictation(token: token, mode: .hold, store: store)
  }

  private func releaseHoldGlobalDictation() {
    guard let token = globalDictationHoldState.release() else { return }
    store?.dictation.stop(target: token)
  }

  private func beginGlobalDictation(token: String, mode: GlobalDictationMode,
    store: WorkspaceStore) {
    do {
      let textTarget = try GlobalDictationTextTarget.capture()
      store.globalDictationHotkeyError = nil
      Task { @MainActor [weak self, weak store] in
        guard let self, let store, self.isCurrentGlobalDictation(token: token, mode: mode) else {
          return
        }
        await store.dictation.start(target: token,
          languageIdentifier: store.voicePreferences.dictationLocaleIdentifier,
          microphoneDeviceID: store.voicePreferences.microphoneDeviceID,
          dictionary: store.voicePreferences.dictationDictionary) { [weak store] _, transcript in
          do {
            try textTarget.insert(transcript)
          } catch {
            store?.globalDictationHotkeyError = error.localizedDescription
            store?.notices.show(id: "global-dictation", title: error.localizedDescription,
              level: .error)
          }
        }
        switch mode {
        case .toggle:
          self.globalDictationState.didResolveStart(token: token,
            active: store.dictation.target == token)
        case .hold:
          if store.dictation.target != token, self.globalDictationHoldState.token == token {
            _ = self.globalDictationHoldState.release()
          }
        }
        if store.dictation.target != token {
          if store.dictation.errorTarget == token, let error = store.dictation.error {
            store.globalDictationHotkeyError = error
            store.notices.show(id: "global-dictation", title: error, level: .error)
          }
        }
      }
    } catch {
      switch mode {
      case .toggle: globalDictationState.cancel(token: token)
      case .hold:
        if globalDictationHoldState.token == token { _ = globalDictationHoldState.release() }
      }
      store.globalDictationHotkeyError = error.localizedDescription
      store.notices.show(id: "global-dictation", title: error.localizedDescription, level: .error)
    }
  }

  private func isCurrentGlobalDictation(token: String, mode: GlobalDictationMode) -> Bool {
    switch mode {
    case .toggle: globalDictationState.token == token
    case .hold: globalDictationHoldState.token == token
    }
  }

  private func captureAppshotFromShortcut() {
    guard let store, store.appshotHotkey != .none, store.shortcutCaptureCount == 0,
      !appshotShortcutPending, store.canBeginAppshotShortcutCapture,
      !store.hasSettingsConfirmation else { return }
    guard let target = store.appshotCapture.availableTarget() else { return }
    let mainWindow = NSApp.windows.first { $0.identifier?.rawValue == "main" }
    let current = AppshotShortcutChat.resolve(lastWindow: lastAppshotWindow,
      mainWindow: mainWindow, store: store, popout: popoutWindowController)
    let recentlyFocused = current.ownerWindow != nil
      && current.ownerWindow === lastAppshotWindow
      && (lastAppshotWindowFocus.map { Date().timeIntervalSince($0) < 60 } ?? false)
    let startNew = current.shouldStartNewChat(destination: store.appshotDestination,
      focusedRecently: recentlyFocused, store: store)
    if startNew && store.busy { return }
    let existingDraftKey = current.draftKey(in: store)
    appshotShortcutPending = true
    Task { @MainActor [weak self, weak store] in
      defer { self?.appshotShortcutPending = false }
      guard let store, store.canBeginAppshotShortcutCapture,
        !store.hasSettingsConfirmation else { return }
      if startNew && store.busy { return }
      if startNew { await store.newChat() }
      let route: AppshotShortcutChat = startNew ? .main(mainWindow) : current
      let draftKey = startNew ? store.draftKey : existingDraftKey
      await store.captureAppshot(draft: draftKey, target: target, mode: .shortcut,
        onScreenshot: { [weak self, weak store] in
          guard let store else { return }
          self?.revealAppshotChat(route, store: store)
          if store.appshotSoundEnabled { NSSound.beep() }
        }, ownerWindow: route.ownerWindow)
    }
  }

  private func revealAppshotChat(_ chat: AppshotShortcutChat, store: WorkspaceStore) {
    switch chat {
    case .main:
      if store.destination != .workspace { store.returnToWorkspace() }
      store.showMainWindowHandler?()
    case .task(let taskID, let window):
      store.taskWindowResources.allObjects.first(where: { $0.window === window })?
        .tasks[taskID]?.activate(nil, focus: false)
      if window.isMiniaturized { window.deminiaturize(nil) }
      NSApp.activate(ignoringOtherApps: true)
      window.makeKeyAndOrderFront(nil)
    case .popout(let taskID, _):
      popoutWindowController?.openThread(taskID)
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
