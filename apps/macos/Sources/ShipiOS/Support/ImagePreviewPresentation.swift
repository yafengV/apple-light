import SwiftUI

/// The task window owns presentation; nested tool cards never create their own sheet.
private struct ImagePreviewPresentationKey: EnvironmentKey {
  static let defaultValue: ((ImagePreviewItem, [ImagePreviewItem], (() -> Void)?) -> Void)? = nil
}
extension EnvironmentValues {
  var presentImageGallery: ((ImagePreviewItem, [ImagePreviewItem], (() -> Void)?) -> Void)? {
    get { self[ImagePreviewPresentationKey.self] }
    set { self[ImagePreviewPresentationKey.self] = newValue }
  }
}
