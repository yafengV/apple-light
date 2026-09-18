import AppKit
import Foundation

extension WorkspaceStore {
  var profileActivity: ProfileActivity { library.profileActivity() }
  var profileAvatar: NSImage? {
    guard profile.hasAvatar else { return nil }
    return NSImage(contentsOf: ProfileStorage.avatarURL(root: dataRoot))
  }

  func loadProfile() async {
    guard !profileLoading else { return }
    profileLoading = true
    defer { profileLoading = false }
    let root = dataRoot
    profileLoaded = false
    do {
      let loaded = try await Task.detached(priority: .userInitiated) {
        try ProfileStorage.load(root: root)
      }.value
      profile = loaded
      profileNameDraft = loaded.displayName
      profileUsernameDraft = loaded.username
      profileLoaded = true
      profileError = nil
      profileAvatarVersion = UUID()
    } catch { profileError = error.localizedDescription }
  }

  @discardableResult func saveUserProfile() -> Bool {
    guard profileLoaded else { return false }
    do {
      var updated = profile
      updated.displayName = profileNameDraft
      updated.username = profileUsernameDraft
      updated = try updated.validated()
      try ProfileStorage.save(updated, root: dataRoot)
      profile = updated
      profileNameDraft = updated.displayName
      profileUsernameDraft = updated.username
      profileError = nil
      return true
    } catch { profileError = error.localizedDescription; return false }
  }

  func chooseProfileAvatar() {
    guard profileLoaded, let window = NSApp.keyWindow else { return }
    let panel = NSOpenPanel()
    panel.title = "选择个人头像"
    panel.allowedContentTypes = [.png, .jpeg, .webP, .gif, .tiff]
    panel.allowsMultipleSelection = false
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      Task { @MainActor in
        do {
          let scoped = url.startAccessingSecurityScopedResource()
          defer { if scoped { url.stopAccessingSecurityScopedResource() } }
          _ = self?.importProfileAvatar(try Data(contentsOf: url, options: .mappedIfSafe))
        } catch { self?.profileError = error.localizedDescription }
      }
    }
  }

  @discardableResult func importProfileAvatar(_ data: Data) -> Bool {
    guard profileLoaded else { return false }
    do {
      let png = try ProfileStorage.normalizedAvatar(data)
      let avatarURL = ProfileStorage.avatarURL(root: dataRoot)
      let old = try? Data(contentsOf: avatarURL)
      try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
      try png.write(to: avatarURL, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: avatarURL.path)
      do {
        var updated = profile
        updated.hasAvatar = true
        try ProfileStorage.save(updated, root: dataRoot)
        profile = updated
      } catch {
        if let old { try? old.write(to: avatarURL, options: .atomic) }
        else { try? FileManager.default.removeItem(at: avatarURL) }
        throw error
      }
      profileAvatarVersion = UUID()
      profileError = nil
      return true
    } catch { profileError = error.localizedDescription; return false }
  }

  @discardableResult func removeProfileAvatar() -> Bool {
    guard profileLoaded, profile.hasAvatar else { return false }
    do {
      var updated = profile
      updated.hasAvatar = false
      try ProfileStorage.save(updated, root: dataRoot)
      profile = updated
      try? FileManager.default.removeItem(at: ProfileStorage.avatarURL(root: dataRoot))
      profileAvatarVersion = UUID()
      profileError = nil
      return true
    } catch { profileError = error.localizedDescription; return false }
  }
}
