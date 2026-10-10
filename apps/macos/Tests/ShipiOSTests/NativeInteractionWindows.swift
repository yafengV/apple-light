import AppKit

/// Window sharing/computer-use observation can add an AppKit-owned overlay to
/// NSApp.windows. It is not a window opened by the tested UI. Keep every other
/// window (including panels) so an extra application dialog still fails.
@MainActor func nativeInteractionWindows() -> [NSWindow] {
  NSApp.windows.filter { String(describing: type(of: $0)) != "NSLocalWindowSharingWindow" }
}
