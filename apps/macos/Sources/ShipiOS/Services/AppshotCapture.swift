import AppKit
import ScreenCaptureKit

struct AppshotCaptureResult: Sendable {
  let data: Data
  let name: String
  let context: AppshotContext?
  let sourceFrame: CGRect?

  init(data: Data, name: String, context: AppshotContext? = nil, sourceFrame: CGRect? = nil) {
    self.data = data; self.name = name; self.context = context; self.sourceFrame = sourceFrame
  }
}

struct AppshotTarget {
  let application: NSRunningApplication
  let windowID: CGWindowID

  var name: String { application.localizedName ?? "应用窗口" }
  var icon: NSImage? { application.icon }
}

enum AppshotTargetOrder {
  static func pids(frontmost: pid_t?, cached: pid_t?, cachedAt: Date?,
    now: Date, ownPID: pid_t) -> [pid_t] {
    var result: [pid_t] = []
    if let frontmost, frontmost != ownPID { result.append(frontmost) }
    if let cached, cached != ownPID, !result.contains(cached),
      let cachedAt, now.timeIntervalSince(cachedAt) <= 300 {
      result.append(cached)
    }
    return result
  }
}

enum AppshotIcon {
  static let maxBytes = 256 * 1_024

  static func pngData(_ icon: NSImage?) -> Data? {
    guard let icon,
      let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let drawing = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = drawing
    icon.draw(in: CGRect(x: 0, y: 0, width: 128, height: 128),
      from: .zero, operation: .sourceOver, fraction: 1)
    drawing.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]),
      png.count <= maxBytes else { return nil }
    return png
  }

  static func image(_ data: Data?) -> NSImage? {
    guard let data, data.count <= maxBytes else { return nil }
    return NSImage(data: data)
  }
}

enum AppshotImage {
  static func sourceFrame(windowFrame: CGRect?, contentRect: CGRect) -> CGRect? {
    for frame in [windowFrame, contentRect].compactMap({ $0 }) {
      guard frame.minX.isFinite, frame.minY.isFinite,
        frame.width.isFinite, frame.height.isFinite,
        frame.width > 0, frame.height > 0,
        frame.width <= 20_000, frame.height <= 20_000 else { continue }
      return frame
    }
    return nil
  }

  static func filename(applicationName: String?, at date: Date = Date()) -> String {
    let rawName = applicationName ?? ""
    let sanitized = rawName.replacingOccurrences(of: "[/:]", with: "-", options: .regularExpression)
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let name = sanitized.isEmpty ? "App" : String(sanitized.prefix(100))
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss.SSS'Z'"
    return "\(name) Appshot \(formatter.string(from: date)).png"
  }

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

  static func encode(_ image: CGImage, applicationName: String?, at date: Date = Date()) throws -> AppshotCaptureResult {
    let bitmap = NSBitmapImageRep(cgImage: image)
    let filename = filename(applicationName: applicationName, at: date)
    if let png = bitmap.representation(using: .png, properties: [:]),
      png.count <= ImageAttachmentStorage.maxBytes {
      return AppshotCaptureResult(data: png, name: filename)
    }
    if let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]),
      jpeg.count <= ImageAttachmentStorage.maxBytes {
      return AppshotCaptureResult(data: jpeg,
        name: String(filename.dropLast(4)) + ".jpg")
    }
    throw AgentFailure(message: "截图超过图片附件大小限制，请缩小目标窗口后重试。")
  }
}

/// Captures the actual frontmost app, then a recent external app, with a picker fallback.
@MainActor final class AppshotCapture: NSObject, SCContentSharingPickerObserver {
  private var continuation: CheckedContinuation<AppshotCaptureResult?, Error>?
  private var onScreenshot: ((AppshotCaptureResult) -> Void)?
  private var pickerCaptureTask: Task<Void, Never>?
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

  func availableTarget() -> AppshotTarget? {
    guard CGPreflightScreenCaptureAccess(),
      let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
        as? [[String: Any]] else { return nil }
    let frontmost = NSWorkspace.shared.frontmostApplication
    let apps = [frontmost, lastExternalApp].compactMap { $0 }
    let order = AppshotTargetOrder.pids(frontmost: frontmost?.processIdentifier,
      cached: lastExternalApp?.processIdentifier, cachedAt: lastExternalAt,
      now: Date(), ownPID: ProcessInfo.processInfo.processIdentifier)
    for pid in order {
      guard let app = apps.first(where: { $0.processIdentifier == pid && !$0.isTerminated }),
        let windowID = AppshotImage.frontWindowID(for: pid, windows: windows) else { continue }
      return AppshotTarget(application: app, windowID: windowID)
    }
    return nil
  }

  func capture(target selectedTarget: AppshotTarget? = nil,
    onScreenshot: ((AppshotCaptureResult) -> Void)? = nil) async throws -> AppshotCaptureResult? {
    guard !busy else { throw AgentFailure(message: "正在截取应用窗口。") }
    busy = true
    self.onScreenshot = onScreenshot
    defer { busy = false; self.onScreenshot = nil }
    if let target = selectedTarget ?? availableTarget(),
      let automatic = try? await captureLastExternalWindow(target) { return automatic }
    try Task.checkCancellation()
    return try await captureFromPicker()
  }

  private func captureLastExternalWindow(_ target: AppshotTarget) async throws -> AppshotCaptureResult? {
    let app = target.application
    guard CGPreflightScreenCaptureAccess(), !app.isTerminated,
      app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
    let content = try await SCShareableContent.current
    guard let window = content.windows.first(where: { $0.windowID == target.windowID }),
      window.owningApplication?.processID == app.processIdentifier else { return nil }
    return try await screenshot(SCContentFilter(desktopIndependentWindow: window),
      applicationName: app.localizedName, bundleIdentifier: app.bundleIdentifier,
      windowTitle: window.title, pid: app.processIdentifier, applicationIcon: app.icon,
      windowFrame: window.frame)
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
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation
        picker.present(using: .window)
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.finish(.success(nil)) }
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
    pickerCaptureTask = Task {
      do {
        let result = try await screenshot(filter,
          applicationName: window?.owningApplication?.applicationName,
          bundleIdentifier: window?.owningApplication?.bundleIdentifier,
          windowTitle: window?.title, pid: window?.owningApplication?.processID,
          applicationIcon: icon(for: window?.owningApplication?.bundleIdentifier),
          windowFrame: window?.frame)
        guard !Task.isCancelled else { return }
        finish(.success(result))
      } catch {
        guard !Task.isCancelled else { return }
        finish(.failure(error))
      }
    }
  }

  private func screenshot(_ filter: SCContentFilter,
    applicationName: String?, bundleIdentifier: String?,
    windowTitle: String?, pid: pid_t?, applicationIcon: NSImage?,
    windowFrame: CGRect?) async throws -> AppshotCaptureResult {
    // AX collection can take up to its 1.5-second deadline. Start it while
    // ScreenCaptureKit is producing the image so the two waits overlap.
    let sourceFrame = AppshotImage.sourceFrame(windowFrame: windowFrame,
      contentRect: filter.contentRect)
    async let axSnapshot = AppshotAccessibility.snapshot(pid: pid,
      windowTitle: windowTitle, windowFrame: sourceFrame)
    let size = AppshotImage.size(rect: filter.contentRect, pixelScale: filter.pointPixelScale)
    let configuration = SCStreamConfiguration()
    configuration.width = size.width
    configuration.height = size.height
    configuration.showsCursor = false
    let image = try await SCScreenshotManager.captureImage(
      contentFilter: filter, configuration: configuration)
    try Task.checkCancellation()
    let encoded = try AppshotImage.encode(image, applicationName: applicationName)
    let iconPNG = AppshotIcon.pngData(applicationIcon)
    let previewContext = AppshotContext(appName: applicationName ?? "应用窗口",
      bundleIdentifier: bundleIdentifier, windowTitle: windowTitle, axTree: "",
      iconPNG: iconPNG)
    onScreenshot?(AppshotCaptureResult(data: encoded.data, name: encoded.name,
      context: previewContext, sourceFrame: sourceFrame))
    let collectedAX = await axSnapshot
    let context = AppshotContext(appName: applicationName ?? "应用窗口",
      bundleIdentifier: bundleIdentifier,
      windowTitle: collectedAX.windowTitle ?? windowTitle, axTree: collectedAX.text,
      iconPNG: iconPNG)
    return AppshotCaptureResult(data: encoded.data, name: encoded.name, context: context,
      sourceFrame: sourceFrame)
  }

  private func icon(for bundleIdentifier: String?) -> NSImage? {
    guard let bundleIdentifier,
      let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
    return NSWorkspace.shared.icon(forFile: appURL.path)
  }

  private func finish(_ result: Result<AppshotCaptureResult?, Error>) {
    guard let continuation else { return }
    self.continuation = nil
    onScreenshot = nil
    pickerCaptureTask?.cancel()
    pickerCaptureTask = nil
    capturing = false
    let picker = SCContentSharingPicker.shared
    picker.remove(self)
    picker.isActive = false
    continuation.resume(with: result)
  }
}
