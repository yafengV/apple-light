import Foundation

extension WorkspaceStore {
  var appearance: AppearancePreferences {
    get { library.appearance ?? AppearancePreferences() }
    set {
      library.appearance = newValue.normalized()
      saveLibrary()
      appearanceHandler?(library.appearance ?? AppearancePreferences())
    }
  }
}
