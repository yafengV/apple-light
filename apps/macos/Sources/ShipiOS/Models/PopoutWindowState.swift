/// The Popout Window has a compact home surface and a separate conversation
/// surface. Hiding either surface retains its route for the next hotkey press.
struct PopoutWindowState: Equatable {
  enum Surface: Equatable {
    case home
    case thread(String)
  }

  private(set) var visibleSurface: Surface?
  private(set) var lastVisibleSurface: Surface = .home

  mutating func toggle() {
    if visibleSurface == nil {
      visibleSurface = lastVisibleSurface
    } else {
      visibleSurface = nil
    }
  }

  mutating func openHome() {
    visibleSurface = .home
    lastVisibleSurface = .home
  }

  mutating func openThread(_ route: String) {
    visibleSurface = .thread(route)
    lastVisibleSurface = .thread(route)
  }

  mutating func hide() {
    visibleSurface = nil
  }
}
