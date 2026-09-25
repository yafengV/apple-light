import AppKit
import SwiftUI
import UserNotifications

@main
struct ShipiOSApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @State private var store = WorkspaceStore()

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
  private var petGlobalHotKey: PetGlobalHotKey?
  private let pointerCursorController = PointerCursorController()
  private var quitting = false
  private var ready = false
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
      let hotKey = PetGlobalHotKey { [weak store] in store?.togglePet() }
      petGlobalHotKey = hotKey
      let refreshHotKey = { [weak hotKey, weak store] in
        guard let hotKey, let store else { return }
        do { try hotKey.register(store.shortcuts.binding("pet")) }
        catch { store.petError = error.localizedDescription }
      }
      store.shortcuts.didChange = { id in if id == "pet" || id == "*" { refreshHotKey() } }
      refreshHotKey()
      store.appearanceHandler = { [weak pointerCursorController] appearance in
        pointerCursorController?.apply(appearance.usePointerCursors)
      }
      pointerCursorController.apply(store.appearance.usePointerCursors)
    }
    ready = true
    await openPendingNotification()
    await openPendingDeepLinks()
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
