import Foundation

struct VoicePreferences: Codable, Equatable {
  var dictationLocaleIdentifier: String?
  var microphoneDeviceID: String?
  var globalHoldHotkey: ShortcutBinding?
  var globalToggleHotkey: ShortcutBinding?
  var dictationDictionary: [String] = []
  var realtimeModelID = ""
  var realtimeVoiceID = "marin"

  init(dictationLocaleIdentifier: String? = nil, microphoneDeviceID: String? = nil,
    globalHoldHotkey: ShortcutBinding? = nil, globalToggleHotkey: ShortcutBinding? = nil,
    dictationDictionary: [String] = [], realtimeModelID: String = "",
    realtimeVoiceID: String = "marin") {
    self.dictationLocaleIdentifier = dictationLocaleIdentifier
    self.microphoneDeviceID = microphoneDeviceID
    self.globalHoldHotkey = globalHoldHotkey
    self.globalToggleHotkey = globalToggleHotkey
    self.dictationDictionary = dictationDictionary
    self.realtimeModelID = realtimeModelID
    self.realtimeVoiceID = realtimeVoiceID
    normalize()
  }

  private enum CodingKeys: CodingKey {
    case dictationLocaleIdentifier, microphoneDeviceID, globalHoldHotkey, globalToggleHotkey,
      dictationDictionary, realtimeModelID, realtimeVoiceID
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    dictationLocaleIdentifier = try values.decodeIfPresent(String.self, forKey: .dictationLocaleIdentifier)
    microphoneDeviceID = try values.decodeIfPresent(String.self, forKey: .microphoneDeviceID)
    globalHoldHotkey = try values.decodeIfPresent(ShortcutBinding.self, forKey: .globalHoldHotkey)
    globalToggleHotkey = try values.decodeIfPresent(ShortcutBinding.self, forKey: .globalToggleHotkey)
    dictationDictionary = try values.decodeIfPresent([String].self, forKey: .dictationDictionary) ?? []
    realtimeModelID = try values.decodeIfPresent(String.self, forKey: .realtimeModelID) ?? ""
    realtimeVoiceID = try values.decodeIfPresent(String.self, forKey: .realtimeVoiceID) ?? "marin"
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
      let word = entry.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !word.isEmpty else { return nil }
      return word
    }
  }
}
