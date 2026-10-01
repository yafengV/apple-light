import AppKit
import ScreenCaptureKit

struct AppshotCaptureResult: Sendable {
  let data: Data
  let name: String
  let context: AppshotContext?

  init(data: Data, name: String, context: AppshotContext? = nil) {
    self.data = data; self.name = name; self.context = context
  }
}

enum AppshotImage {
  static func frontWindowID(for pid: pid_t, windows: [[String: Any]]) -> CGWindowID? {
    for info in windows {
      guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
        (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
        let frame = info[kCGWindowBounds as String] as? [String: Any],
        (frame["Width"] as? NSNumber)?.doubleValue ?? 0 >= 64,
        (frame["Height"] as? NSNumber)?.doubleValue ?? 0 >= 64,
        let number = info[kCGWindowNumber as String] as? NSNumber else { continue }
      return CGWindowID(number.uint32Value)
    }
    return nil
  }

  static func size(rect: CGRect, pixelScale: Float) -> (width: Int, height: Int) {
    let scale = pixelScale.isFinite && pixelScale > 0 ? CGFloat(pixelScale) : 1
    let sourceWidth = max(1, rect.width * scale)
    let sourceHeight = max(1, rect.height * scale)
    let ratio = min(1, 3_200 / max(sourceWidth, sourceHeight))
    return (max(1, Int((sourceWidth * ratio).rounded())),
      max(1, Int((sourceHeight * ratio).rounded())))
  }

  static func encode(_ image: CGImage, applicationName: String?) throws -> AppshotCaptureResult {
    let bitmap = NSBitmapImageRep(cgImage: image)
    let title = applicationName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = title.flatMap { $0.isEmpty ? nil : String($0.prefix(100)) } ?? "应用窗口"
    if let png = bitmap.representation(using: .png, properties: [:]),
      png.count <= ImageAttachmentStorage.maxBytes {
      return AppshotCaptureResult(data: png, name: "\(prefix) 截图.png")
    }
    if let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]),
      jpeg.count <= ImageAttachmentStorage.maxBytes {
      return AppshotCaptureResult(data: jpeg, name: "\(prefix) 截图.jpg")
    }
    throw AgentFailure(message: "截图超过图片附件大小限制，请缩小目标窗口后重试。")
  }
}

/// Uses a recent foreground window when authorized, with a system picker fallback.
@MainActor final class AppshotCapture: NSObject, SCContentSharingPickerObserver {
  private var continuation: CheckedContinuation<AppshotCaptureResult?, Error>?
  private var capturing = false
  private var busy = false
  private var lastExternalApp: NSRunningApplication?
  private var lastExternalAt: Date?
  private var activationObserver: NSObjectProtocol?

  override init() {
    super.init()
    let ownPID = ProcessInfo.processInfo.processIdentifier
    if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ownPID {
      lastExternalApp = app
      lastExternalAt = Date()
    }
    activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
      guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
        app.processIdentifier != ownPID else { return }
      Task { @MainActor [weak self] in
        guard self?.busy == false else { return }
        self?.lastExternalApp = app
        self?.lastExternalAt = Date()
      }
    }
  }

  deinit {
    if let activationObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
    }
  }

  func capture() async throws -> AppshotCaptureResult? {
    guard !busy else { throw AgentFailure(message: "正在截取应用窗口。") }
    busy = true
    defer { busy = false }
    if let automatic = try? await captureLastExternalWindow() { return automatic }
    return try await captureFromPicker()
  }

  private func captureLastExternalWindow() async throws -> AppshotCaptureResult? {
    guard CGPreflightScreenCaptureAccess(),
      let lastExternalAt, Date().timeIntervalSince(lastExternalAt) <= 300,
      let app = lastExternalApp, !app.isTerminated,
      app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
      let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
        as? [[String: Any]],
      let windowID = AppshotImage.frontWindowID(for: app.processIdentifier, windows: windows)
    else { return nil }
    let content = try await SCShareableContent.current
    guard let window = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
    return try await screenshot(SCContentFilter(desktopIndependentWindow: window),
      applicationName: app.localizedName, bundleIdentifier: app.bundleIdentifier,
      windowTitle: window.title, pid: app.processIdentifier)
  }

  private func captureFromPicker() async throws -> AppshotCaptureResult? {
    let picker = SCContentSharingPicker.shared
    var configuration = SCContentSharingPickerConfiguration()
    configuration.allowedPickerModes = [.singleWindow]
    configuration.excludedBundleIDs = Bundle.main.bundleIdentifier.map { [$0] } ?? []
    configuration.allowsChangingSelectedContent = false
    picker.defaultConfiguration = configuration
    picker.maximumStreamCount = 1
    picker.add(self)
    picker.isActive = true
    return try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      picker.present(using: .window)
    }
  }

  nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker,
    didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
    Task { @MainActor [weak self] in self?.capture(filter) }
  }

  nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker,
    didCancelFor stream: SCStream?) {
    Task { @MainActor [weak self] in self?.finish(.success(nil)) }
  }

  nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
    Task { @MainActor [weak self] in self?.finish(.failure(error)) }
  }

  private func capture(_ filter: SCContentFilter) {
    guard continuation != nil, !capturing else { return }
    capturing = true
    var window: SCWindow?
    if #available(macOS 15.2, *) {
      window = filter.includedWindows.first
    }
    Task {
      do {
        finish(.success(try await screenshot(filter,
          applicationName: window?.owningApplication?.applicationName,
          bundleIdentifier: window?.owningApplication?.bundleIdentifier,
          windowTitle: window?.title, pid: window?.owningApplication?.processID)))
      } catch { finish(.failure(error)) }
    }
  }

  private func screenshot(_ filter: SCContentFilter,
    applicationName: String?, bundleIdentifier: String?,
    windowTitle: String?, pid: pid_t?) async throws -> AppshotCaptureResult {
    let size = AppshotImage.size(rect: filter.contentRect, pixelScale: filter.pointPixelScale)
    let configuration = SCStreamConfiguration()
    configuration.width = size.width
    configuration.height = size.height
    configuration.showsCursor = false
    let image = try await SCScreenshotManager.captureImage(
      contentFilter: filter, configuration: configuration)
    let encoded = try AppshotImage.encode(image, applicationName: applicationName)
    let axTree = await AppshotAccessibility.snapshot(pid: pid, windowTitle: windowTitle)
    let context = AppshotContext(appName: applicationName ?? "应用窗口",
      bundleIdentifier: bundleIdentifier, windowTitle: windowTitle, axTree: axTree)
    return AppshotCaptureResult(data: encoded.data, name: encoded.name, context: context)
  }

  private func finish(_ result: Result<AppshotCaptureResult?, Error>) {
    guard let continuation else { return }
    self.continuation = nil
    capturing = false
    let picker = SCContentSharingPicker.shared
    picker.remove(self)
    picker.isActive = false
    continuation.resume(with: result)
  }
}
