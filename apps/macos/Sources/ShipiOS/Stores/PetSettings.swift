import AppKit
import Foundation

extension WorkspaceStore {
  var petActivityStatus: PetActivityStatus {
    if attentionTasks.contains(where: { taskAttentionKind(for: $0)?.requiresAction == true }) {
      return .needsInput
    }
    if activeRun != nil || hasLiveModelRequests { return .running }
    if let selectedRun, selectedRun.status == "failed" { return .blocked }
    if !library.unreadTasks.isEmpty { return .ready }
    return .idle
  }

  var petCustomImage: NSImage? { petCustomData.flatMap(NSImage.init(data:)) }

  func loadPets() async {
    guard !petsLoading else { return }
    petsLoading = true
    defer { petsLoading = false }
    petsLoaded = false
    let root = dataRoot
    do {
      let loaded = try await Task.detached(priority: .userInitiated) {
        try PetStorage.load(root: root)
      }.value
      petPreferences = loaded.0
      petCustomData = loaded.1
      petsLoaded = true
      petError = nil
    } catch { petError = error.localizedDescription }
  }

  @discardableResult func selectPet(_ kind: PetKind) -> Bool {
    guard petsLoaded, kind != .custom || petPreferences.hasCustomPet else { return false }
    var updated = petPreferences
    updated.selected = kind
    return savePetPreferences(updated)
  }

  @discardableResult func setPetVisible(_ visible: Bool) -> Bool {
    guard petsLoaded else { return false }
    var updated = petPreferences
    updated.visible = visible
    return savePetPreferences(updated)
  }

  func togglePet() { _ = setPetVisible(!petPreferences.visible) }

  @discardableResult func setPetScale(_ scale: Double) -> Bool {
    guard petsLoaded else { return false }
    var updated = petPreferences
    updated.scale = scale
    return savePetPreferences(updated)
  }

  @discardableResult func resetPetScale() -> Bool { setPetScale(1) }

  func savePetPosition(_ origin: NSPoint) {
    guard petsLoaded else { return }
    var updated = petPreferences
    updated.originX = origin.x
    updated.originY = origin.y
    do {
      try PetStorage.save(updated, root: dataRoot)
      petPreferences = updated
      petError = nil
    } catch { petError = error.localizedDescription }
  }

  func chooseCustomPet() {
    guard petsLoaded, let window = NSApp.keyWindow else { return }
    let panel = NSOpenPanel()
    panel.title = "导入自定义宠物"
    panel.allowedContentTypes = [.png, .webP]
    panel.allowsMultipleSelection = false
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      Task { @MainActor in
        do {
          let scoped = url.startAccessingSecurityScopedResource()
          defer { if scoped { url.stopAccessingSecurityScopedResource() } }
          _ = self?.importCustomPet(
            try Data(contentsOf: url, options: .mappedIfSafe),
            name: url.deletingPathExtension().lastPathComponent)
        } catch { self?.petError = error.localizedDescription }
      }
    }
  }

  @discardableResult func importCustomPet(_ data: Data, name: String) -> Bool {
    guard petsLoaded else { return false }
    do {
      _ = try PetStorage.validateAsset(data)
      let url = PetStorage.customAssetURL(root: dataRoot)
      let oldData = try? Data(contentsOf: url)
      try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
      try data.write(to: url, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      do {
        var updated = petPreferences
        updated.hasCustomPet = true
        updated.customName = name
        updated.selected = .custom
        try PetStorage.save(updated, root: dataRoot)
        petPreferences = try updated.validated(customAssetExists: true)
        petCustomData = data
      } catch {
        if let oldData { try? oldData.write(to: url, options: .atomic) }
        else { try? FileManager.default.removeItem(at: url) }
        throw error
      }
      petAssetVersion = UUID()
      petError = nil
      petPanelHandler?(petPreferences)
      return true
    } catch { petError = error.localizedDescription; return false }
  }

  @discardableResult func removeCustomPet() -> Bool {
    guard petsLoaded, petPreferences.hasCustomPet else { return false }
    do {
      let assetURL = PetStorage.customAssetURL(root: dataRoot)
      let oldData = try Data(contentsOf: assetURL)
      var updated = petPreferences
      updated.hasCustomPet = false
      updated.customName = ""
      if updated.selected == .custom { updated.selected = .codey }
      try FileManager.default.removeItem(at: assetURL)
      do {
        try PetStorage.save(updated, root: dataRoot)
      } catch {
        try? oldData.write(to: assetURL, options: .atomic)
        throw error
      }
      petPreferences = updated
      petCustomData = nil
      petAssetVersion = UUID()
      petError = nil
      petPanelHandler?(updated)
      return true
    } catch { petError = error.localizedDescription; return false }
  }

  func showPetChat() {
    NSApp.activate(ignoringOtherApps: true)
    Task {
      await newProjectlessTask()
      if project == nil { focusComposer = UUID() }
    }
  }

  func sendPetPrompt(_ prompt: String) async -> Bool {
    let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty else { return false }
    NSApp.activate(ignoringOtherApps: true)
    await newProjectlessTask()
    guard project == nil, selection == nil else {
      error = "当前任务仍在运行，无法从宠物控件创建新会话。"
      return false
    }
    draft = prompt
    await sendDraft()
    return draft.isEmpty
  }

  private func savePetPreferences(_ updated: PetPreferences) -> Bool {
    do {
      try PetStorage.save(updated, root: dataRoot)
      petPreferences = try updated.validated(
        customAssetExists: FileManager.default.fileExists(
          atPath: PetStorage.customAssetURL(root: dataRoot).path))
      petError = nil
      petPanelHandler?(petPreferences)
      return true
    } catch { petError = error.localizedDescription; return false }
  }
}
