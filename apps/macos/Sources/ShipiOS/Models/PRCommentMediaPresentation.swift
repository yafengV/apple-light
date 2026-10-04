import AppKit
import Observation

@MainActor @Observable final class PRCommentMediaPresentation {
  enum Phase { case loading, image(NSImage), unavailable(external: Bool) }
  private(set) var phase: Phase = .loading
  @ObservationIgnored private var operation = UUID()
  @ObservationIgnored private var currentURL: URL?
  @ObservationIgnored private var currentKind: GitHubPRCommentMedia.Kind?

  func load(_ media: GitHubPRCommentMedia,
    using loader: @Sendable (GitHubPRCommentMedia) async throws -> GitHubPRCommentMediaLoader.Payload) async {
    let id = UUID(); operation = id; currentURL = media.url; currentKind = media.kind; phase = .loading
    do {
      let payload = try await loader(media)
      guard operation == id, !Task.isCancelled else { return }
      guard GitHubPRCommentMediaLoader.accepts(payload.mimeType, kind: media.kind) else {
        phase = .unavailable(external: false); return
      }
      // The PR renderer explicitly disables playable media. A video directive
      // can still contain an image response; only that response is embedded.
      if media.kind == .video, !GitHubPRCommentMediaLoader.normalizedMIME(payload.mimeType).hasPrefix("image/") {
        phase = .unavailable(external: true)
      } else if let image = NSImage(data: payload.data), image.isValid {
        phase = .image(image)
      } else { phase = .unavailable(external: false) }
    } catch {
      guard operation == id, !Task.isCancelled, !(error is CancellationError) else { return }
      phase = .unavailable(external: false)
    }
  }
  func cancel() {
    operation = UUID(); currentURL = nil; currentKind = nil; phase = .loading
  }
  func canOpen(_ media: GitHubPRCommentMedia) -> Bool {
    guard currentURL == media.url, currentKind == media.kind,
      GitHubPRCommentMedia.allowedURL(media.url.absoluteString) != nil else { return false }
    if case .unavailable = phase { return true }; return false
  }
  func open(_ media: GitHubPRCommentMedia, normally: (URL) -> Void, externally: (URL) -> Void) {
    guard canOpen(media), case .unavailable(let external) = phase else { return }
    if external { externally(media.url) } else { normally(media.url) }
  }
}

struct PRCommentMediaImageMetrics {
  static func size(intrinsic: CGSize, width: CGFloat?, viewportHeight: CGFloat) -> CGSize {
    guard intrinsic.width.isFinite, intrinsic.height.isFinite, intrinsic.width > 0, intrinsic.height > 0 else { return .zero }
    let available = width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? intrinsic.width
    let maximumHeight = viewportHeight.isFinite ? min(640, max(0, viewportHeight) * 0.7) : 640
    let scale = min(1, available / intrinsic.width, maximumHeight / intrinsic.height)
    return .init(width: intrinsic.width * scale, height: intrinsic.height * scale)
  }
}
