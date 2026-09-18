import AppKit
import SwiftUI

struct NotificationSettingsView: View {
  @Bindable var store: WorkspaceStore
  @State private var testSent = false

  var body: some View {
    Form {
      Section("任务结束") {
        SettingsMenuPicker("显示通知", selection: binding(\.timing),
          options: CompletionNotificationTiming.allCases.map {
            SettingsMenuOption(value: $0, title: $0.title)
          })
        .settingsSearchTarget(.notificationTiming)
        Toggle("需要通知时询问系统权限", isOn: binding(\.promptForPermission)).settingsSearchTarget(.notificationPrompt)
        Text("通知已完成或失败的任务；主动停止的任务不提醒。点击通知可返回对应任务。")
          .appFont(.caption).foregroundStyle(.secondary)
      }
      Section("系统权限") {
        LabeledContent("通知权限", value: store.notifications.permission.title).settingsSearchTarget(.notificationPermission)
        HStack {
          Button(store.notifications.requesting ? "正在请求…" : "允许通知") {
            Task { await store.notifications.requestPermission() }
          }.disabled(store.notifications.requesting || store.notifications.permission != .notDetermined)
          Button("打开系统设置…") {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
          }
          Button("刷新状态") { Task { await store.notifications.refreshPermission() } }
        }
        Text("在系统设置 → 通知 → ShipiOS 中管理横幅、声音和锁屏显示。系统专注模式可能影响通知呈现。")
          .appFont(.caption).foregroundStyle(.secondary)
      }
      Section {
        Button("发送测试通知") {
          Task {
            await store.notifications.sendTest()
            testSent = store.notifications.error == nil && store.notifications.permission == .authorized
          }
        }.disabled(store.notifications.permission != .authorized).settingsSearchTarget(.notificationTest)
        if testSent { Text("测试通知已交给系统。").foregroundStyle(.secondary) }
        if let error = store.notifications.error {
          Text(error).foregroundStyle(.red).textSelection(.enabled)
        }
      }
    }.settingsFormStyle().appSurface()
      .task(id: store.settingsPage) {
        guard store.settingsPage == .notifications else { return }
        await store.notifications.refreshPermission()
      }
      .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
        guard store.settingsPage == .notifications else { return }
        Task { await store.notifications.refreshPermission() }
      }
  }

  private func binding<Value>(_ key: WritableKeyPath<CompletionNotificationPreferences, Value>) -> Binding<Value> {
    Binding(
      get: { store.notificationPreferences[keyPath: key] },
      set: { var updated = store.notificationPreferences; updated[keyPath: key] = $0; store.notificationPreferences = updated })
  }
}
