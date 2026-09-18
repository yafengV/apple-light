import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

extension WorkspaceStore {
  func loadComputerUsePreferences() async {
    guard !computerUseLoading else { return }
    computerUseLoading = true
    defer { computerUseLoading = false }
    computerUseLoaded = false
    let root = dataRoot
    do {
      computerUsePreferences = try await Task.detached(priority: .userInitiated) {
        try ComputerUseStorage.load(root: root)
      }.value
      computerUseLoaded = true
      computerUseError = nil
    } catch { computerUseError = error.localizedDescription }
    refreshComputerUsePermissions()
  }

  func refreshComputerUsePermissions() {
    screenRecordingGranted = CGPreflightScreenCaptureAccess()
    accessibilityGranted = AXIsProcessTrusted()
    computerUseLastChecked = Date()
  }

  @discardableResult func setAnyAppComputerUse(_ enabled: Bool) -> Bool {
    guard computerUseLoaded else { return false }
    var updated = computerUsePreferences
    updated.anyAppEnabled = enabled
    return saveComputerUsePreferences(updated)
  }

  func chooseAlwaysAllowedApplication() {
    guard computerUseLoaded, let window = NSApp.keyWindow else { return }
    let panel = NSOpenPanel()
    panel.title = "选择始终允许的应用"
    panel.prompt = "允许"
    panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    panel.allowedContentTypes = [.applicationBundle]
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      Task { @MainActor in _ = self?.addAlwaysAllowedApplication(url) }
    }
  }

  @discardableResult func addAlwaysAllowedApplication(_ url: URL) -> Bool {
    guard computerUseLoaded, url.pathExtension.lowercased() == "app",
      let bundle = Bundle(url: url)
    else {
      computerUseError = "请选择有效的 macOS 应用。"
      return false
    }
    let application = ComputerUseApplication(
      name: FileManager.default.displayName(atPath: url.path),
      bundleIdentifier: bundle.bundleIdentifier,
      path: url.standardizedFileURL.path)
    var updated = computerUsePreferences
    updated.alwaysAllowedApplications.removeAll { $0.id == application.id }
    updated.alwaysAllowedApplications.append(application)
    updated.alwaysAllowedApplications.sort {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
    return saveComputerUsePreferences(updated)
  }

  @discardableResult func removeAlwaysAllowedApplication(_ application: ComputerUseApplication) -> Bool {
    guard computerUseLoaded else { return false }
    var updated = computerUsePreferences
    updated.alwaysAllowedApplications.removeAll { $0.id == application.id }
    return saveComputerUsePreferences(updated)
  }

  func requestScreenRecordingAccess() {
    screenRecordingGranted = CGRequestScreenCaptureAccess()
    computerUseLastChecked = Date()
  }

  func requestAccessibilityAccess() {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let options = [key: true] as CFDictionary
    accessibilityGranted = AXIsProcessTrustedWithOptions(options)
    computerUseLastChecked = Date()
  }

  func openScreenRecordingSettings() {
    openComputerUseSystemSettings("Privacy_ScreenCapture")
  }

  func openAccessibilitySettings() {
    openComputerUseSystemSettings("Privacy_Accessibility")
  }

  private func openComputerUseSystemSettings(_ pane: String) {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"),
      NSWorkspace.shared.open(url)
    else {
      computerUseError = "无法打开 macOS 隐私与安全性设置。"
      return
    }
    computerUseError = nil
  }

  private func saveComputerUsePreferences(_ updated: ComputerUsePreferences) -> Bool {
    do {
      try ComputerUseStorage.save(updated, root: dataRoot)
      computerUsePreferences = updated.validated()
      computerUseError = nil
      return true
    } catch {
      computerUseError = error.localizedDescription
      return false
    }
  }
}
