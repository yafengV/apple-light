import Carbon.HIToolbox
import Foundation

/// Carbon's event identifier belongs to a registration, not permanently to a
/// command. Keep its handler alive when an atomic batch transfers that binding.
@MainActor final class GlobalHotkeyEventRoute {
  private final class WeakRoute { weak var value: GlobalHotkeyEventRoute? }
  private static var routes: [UInt32: WeakRoute] = [:]
  private static var nextID: UInt32 = 0x8000_0000
  let identifier: EventHotKeyID
  private(set) var handler: EventHandlerRef?
  weak var owner: AppGlobalHotKey?
  private weak var pressedOwner: AppGlobalHotKey?
  private var hasPressedOwner = false

  static func make(preferredID: UInt32? = nil) -> GlobalHotkeyEventRoute {
    routes = routes.filter { $0.value.value != nil }
    let id: UInt32
    if let preferredID, routes[preferredID] == nil { id = preferredID }
    else {
      while routes[nextID] != nil { nextID &+= 1 }
      id = nextID; nextID &+= 1
    }
    let route = GlobalHotkeyEventRoute(id: id)
    let weak = WeakRoute(); weak.value = route; routes[id] = weak
    return route
  }

  private init(id: UInt32) {
    identifier = EventHotKeyID(signature: 0x5348_4950, id: id)
    let events = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
      EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
    let callback: EventHandlerUPP = { _, event, context in
      guard let event, let context else { return OSStatus(eventNotHandledErr) }
      var identifier = EventHotKeyID()
      let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
      guard status == noErr, Thread.isMainThread else { return OSStatus(eventNotHandledErr) }
      let route = Unmanaged<GlobalHotkeyEventRoute>.fromOpaque(context).takeUnretainedValue()
      let delivery: (@MainActor () -> Void)? = MainActor.assumeIsolated {
        guard identifier.signature == route.identifier.signature,
          identifier.id == route.identifier.id else { return nil }
        return route.delivery(released: GetEventKind(event) == UInt32(kEventHotKeyReleased))
      }
      guard let delivery else { return OSStatus(eventNotHandledErr) }
      Task { @MainActor in delivery() }
      return noErr
    }
    let status = events.withUnsafeBufferPointer { buffer in
      InstallEventHandler(GetApplicationEventTarget(), callback, buffer.count, buffer.baseAddress,
        Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    if status != noErr { handler = nil }
  }

  private func delivery(released: Bool) -> (@MainActor () -> Void) {
    if released {
      let recipient = hasPressedOwner ? pressedOwner : owner
      hasPressedOwner = false; pressedOwner = nil
      return recipient?.delivery(released: true) ?? {}
    }
    // A repeat from a held, transferred binding cannot start its new command.
    if hasPressedOwner, pressedOwner !== owner { return {} }
    guard let owner else { return {} }
    pressedOwner = owner; hasPressedOwner = true
    return owner.delivery(released: false)
  }

  deinit { if let handler { RemoveEventHandler(handler) } }
}
