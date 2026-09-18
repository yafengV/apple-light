import Foundation

extension WorkspaceStore {
  private var panelLayoutKey: String { project?.path ?? "default" }
  var panelSizes: WorkspacePanelSizes {
    library.panelSizes[panelLayoutKey] ?? WorkspacePanelSizes()
  }

  func resizeInspector(to width: Double) {
    guard width.isFinite, width >= 0 else { return }
    var sizes = panelSizes
    sizes.inspectorWidth = width
    library.panelSizes[panelLayoutKey] = sizes
  }
  func resizeTerminal(to height: Double) {
    guard height.isFinite, height >= 0 else { return }
    var sizes = panelSizes
    sizes.terminalHeight = height
    library.panelSizes[panelLayoutKey] = sizes
  }
  func resetInspectorSize() {
    var sizes = panelSizes
    sizes.inspectorWidth = nil
    library.panelSizes[panelLayoutKey] = sizes
    saveLibrary()
  }
  func resetTerminalSize() {
    var sizes = panelSizes
    sizes.terminalHeight = nil
    library.panelSizes[panelLayoutKey] = sizes
    saveLibrary()
  }
}
