import Foundation

struct VoicePreferences: Codable, Equatable {
  var dictationLocaleIdentifier: String?
  var microphoneDeviceID: String?
  var globalToggleHotkey: ShortcutBinding?
  var dictationDictionary: [String] = []

  init(dictationLocaleIdentifier: String? = nil, microphoneDeviceID: String? = nil,
    globalToggleHotkey: ShortcutBinding? = nil, dictationDictionary: [String] = []) {
    self.dictationLocaleIdentifier = dictationLocaleIdentifier
    self.microphoneDeviceID = microphoneDeviceID
    self.globalToggleHotkey = globalToggleHotkey
    self.dictationDictionary = dictationDictionary
    normalize()
  }

  private enum CodingKeys: CodingKey {
    case dictationLocaleIdentifier, microphoneDeviceID, globalToggleHotkey, dictationDictionary
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    dictationLocaleIdentifier = try values.decodeIfPresent(String.self, forKey: .dictationLocaleIdentifier)
    microphoneDeviceID = try values.decodeIfPresent(String.self, forKey: .microphoneDeviceID)
    globalToggleHotkey = try values.decodeIfPresent(ShortcutBinding.self, forKey: .globalToggleHotkey)
    dictationDictionary = try values.decodeIfPresent([String].self, forKey: .dictationDictionary) ?? []
    normalize()
  }

  mutating func normalize() {
    dictationLocaleIdentifier = dictationLocaleIdentifier?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if dictationLocaleIdentifier?.isEmpty == true { dictationLocaleIdentifier = nil }
    microphoneDeviceID = microphoneDeviceID?.trimmingCharacters(in: .whitespacesAndNewlines)
    if microphoneDeviceID?.isEmpty == true { microphoneDeviceID = nil }
    dictationDictionary = dictationDictionary.compactMap { entry in
      let word = entry.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !word.isEmpty else { return nil }
      return word
    }
  }
}
