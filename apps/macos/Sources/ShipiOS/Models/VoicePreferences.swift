import Foundation

struct VoicePreferences: Codable, Equatable {
  var dictationLocaleIdentifier: String?
  var microphoneDeviceID: String?
  var globalHoldHotkey: ShortcutBinding?
  var globalToggleHotkey: ShortcutBinding?
  var globalVoiceChatHotkey: ShortcutBinding?
  var dictationDictionary: [String] = []
  var realtimeModelID = ""
  var realtimeVoiceID = "marin"
  var screenContextEnabled = false

  subscript(mode: VoiceShortcutPresentation.Mode) -> ShortcutBinding? {
    get {
      switch mode {
      case .hold: globalHoldHotkey
      case .toggle: globalToggleHotkey
      case .voiceChat: globalVoiceChatHotkey
      }
    }
    set {
      switch mode {
      case .hold: globalHoldHotkey = newValue
      case .toggle: globalToggleHotkey = newValue
      case .voiceChat: globalVoiceChatHotkey = newValue
      }
    }
  }

  init(dictationLocaleIdentifier: String? = nil, microphoneDeviceID: String? = nil,
    globalHoldHotkey: ShortcutBinding? = nil, globalToggleHotkey: ShortcutBinding? = nil,
    globalVoiceChatHotkey: ShortcutBinding? = nil,
    dictationDictionary: [String] = [], realtimeModelID: String = "",
    realtimeVoiceID: String = "marin", screenContextEnabled: Bool = false) {
    self.dictationLocaleIdentifier = dictationLocaleIdentifier
    self.microphoneDeviceID = microphoneDeviceID
    self.globalHoldHotkey = globalHoldHotkey
    self.globalToggleHotkey = globalToggleHotkey
    self.globalVoiceChatHotkey = globalVoiceChatHotkey
    self.dictationDictionary = dictationDictionary
    self.realtimeModelID = realtimeModelID
    self.realtimeVoiceID = realtimeVoiceID
    self.screenContextEnabled = screenContextEnabled
    normalize()
  }

  private enum CodingKeys: CodingKey {
    case dictationLocaleIdentifier, microphoneDeviceID, globalHoldHotkey, globalToggleHotkey,
      globalVoiceChatHotkey,
      dictationDictionary, realtimeModelID, realtimeVoiceID, screenContextEnabled
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    dictationLocaleIdentifier = try values.decodeIfPresent(String.self, forKey: .dictationLocaleIdentifier)
    microphoneDeviceID = try values.decodeIfPresent(String.self, forKey: .microphoneDeviceID)
    globalHoldHotkey = try values.decodeIfPresent(ShortcutBinding.self, forKey: .globalHoldHotkey)
    globalToggleHotkey = try values.decodeIfPresent(ShortcutBinding.self, forKey: .globalToggleHotkey)
    globalVoiceChatHotkey = try values.decodeIfPresent(ShortcutBinding.self, forKey: .globalVoiceChatHotkey)
    dictationDictionary = try values.decodeIfPresent([String].self, forKey: .dictationDictionary) ?? []
    realtimeModelID = try values.decodeIfPresent(String.self, forKey: .realtimeModelID) ?? ""
    realtimeVoiceID = try values.decodeIfPresent(String.self, forKey: .realtimeVoiceID) ?? "marin"
    screenContextEnabled = try values.decodeIfPresent(Bool.self, forKey: .screenContextEnabled) ?? false
    normalize()
  }

  mutating func normalize() {
    dictationLocaleIdentifier = dictationLocaleIdentifier?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if dictationLocaleIdentifier?.isEmpty == true { dictationLocaleIdentifier = nil }
    microphoneDeviceID = microphoneDeviceID?.trimmingCharacters(in: .whitespacesAndNewlines)
    if microphoneDeviceID?.isEmpty == true { microphoneDeviceID = nil }
    realtimeModelID = realtimeModelID.trimmingCharacters(in: .whitespacesAndNewlines)
    realtimeVoiceID = realtimeVoiceID.trimmingCharacters(in: .whitespacesAndNewlines)
    if realtimeVoiceID.isEmpty { realtimeVoiceID = "marin" }
    dictationDictionary = dictationDictionary.compactMap { entry in
      let word = entry.trimmingCharacters(in: Self.dictionaryWhitespace)
      guard !word.isEmpty else { return nil }
      return word
    }
  }

  // Match the reference dictionary's String.trim(): FEFF is whitespace while
  // NEL, Mongolian vowel separator and zero-width space are retained.
  private static let dictionaryWhitespace = CharacterSet(charactersIn:
    "\u{0009}\u{000a}\u{000b}\u{000c}\u{000d}\u{0020}\u{00a0}\u{1680}" +
    "\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200a}" +
    "\u{2028}\u{2029}\u{202f}\u{205f}\u{3000}\u{feff}")
}
