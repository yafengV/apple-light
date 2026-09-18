import Foundation
import Observation
import UserNotifications

enum NotificationPermission: Equatable {
  case unknown, notDetermined, authorized, denied
  var title: String {
    switch self {
    case .unknown: "正在读取"
    case .notDetermined: "尚未请求"
    case .authorized: "已允许"
    case .denied: "未允许，请在系统设置中开启"
    }
  }
}

@MainActor protocol NotificationDelivery {
  func permission() async -> NotificationPermission
  func requestPermission() async throws
  func post(_ notice: CompletionNotice) async throws
}

@MainActor struct SystemNotificationDelivery: NotificationDelivery {
  func permission() async -> NotificationPermission {
    switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
    case .notDetermined: .notDetermined
    case .authorized, .provisional: .authorized
    case .denied: .denied
    @unknown default: .unknown
    }
  }
  func requestPermission() async throws {
    _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
  }
  func post(_ notice: CompletionNotice) async throws {
    let content = UNMutableNotificationContent()
    content.title = notice.title
    content.body = notice.body
    content.sound = .default
    content.userInfo = notice.destination?.userInfo ?? [:]
    try await UNUserNotificationCenter.current().add(
      UNNotificationRequest(identifier: notice.id, content: content, trigger: nil))
  }
}

@MainActor @Observable final class CompletionNotificationCenter {
  private(set) var permission: NotificationPermission = .unknown
  private(set) var requesting = false
  var error: String?
  @ObservationIgnored private let delivery: any NotificationDelivery
  @ObservationIgnored private var prompted = false

  init(delivery: (any NotificationDelivery)? = nil) {
    self.delivery = delivery ?? SystemNotificationDelivery()
  }

  func refreshPermission() async { permission = await delivery.permission() }

  func requestPermission() async {
    guard !requesting else { return }
    requesting = true
    prompted = true
    defer { requesting = false }
    do {
      try await delivery.requestPermission()
      permission = await delivery.permission()
      error = nil
    } catch { self.error = error.localizedDescription }
  }

  func deliver(
    _ notice: CompletionNotice,
    currentState: () -> (CompletionNotificationPreferences, Bool)
  ) async {
    var state = currentState()
    guard state.0.permits(appIsActive: state.1) else { return }
    await refreshPermission()
    state = currentState()
    guard state.0.permits(appIsActive: state.1) else { return }
    if permission == .notDetermined, state.0.promptForPermission, !prompted {
      await requestPermission()
    }
    state = currentState()
    guard permission == .authorized, state.0.permits(appIsActive: state.1) else { return }
    do { try await delivery.post(notice); error = nil }
    catch { self.error = error.localizedDescription }
  }

  func sendTest() async {
    await refreshPermission()
    guard permission == .authorized else { return }
    do {
      try await delivery.post(CompletionNotice(
        id: "test:\(UUID())", title: "ShipiOS 测试通知", body: "任务结束通知已就绪。", destination: nil))
      error = nil
    } catch { self.error = error.localizedDescription }
  }
}
