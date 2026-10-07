import Foundation

enum ShipiOSResources {
  static let bundle: Bundle = {
    guard let bundle = resolve(main: .main, development: { .module }) else {
      preconditionFailure("The packaged ShipiOS resource bundle is missing.")
    }
    return bundle
  }()

  /// SwiftPM's generated accessor checks beside the executable bundle and
  /// then the build cache. A macOS app ships its resources inside Contents.
  /// Never silently use a developer's cache when a packaged app is incomplete.
  static func resolve(main: Bundle, development: () -> Bundle) -> Bundle? {
    if main.bundleURL.pathExtension == "app" {
      return main.resourceURL.flatMap { Bundle(url: $0.appendingPathComponent("ShipiOS_ShipiOS.bundle")) }
    }
    return development()
  }
}
