import Foundation

struct VoicePreferences: Codable, Equatable {
  var dictationLocaleIdentifier: String?
  var microphoneDeviceID: String?
  var dictationDictionary: [String] = []

  init(dictationLocaleIdentifier: String? = nil, microphoneDeviceID: String? = nil,
    dictationDictionary: [String] = []) {
    self.dictationLocaleIdentifier = dictationLocaleIdentifier
    self.microphoneDeviceID = microphoneDeviceID
    self.dictationDictionary = dictationDictionary
    normalize()
  }

  private enum CodingKeys: CodingKey {
    case dictationLocaleIdentifier, microphoneDeviceID, dictationDictionary
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    dictationLocaleIdentifier = try values.decodeIfPresent(String.self, forKey: .dictationLocaleIdentifier)
    microphoneDeviceID = try values.decodeIfPresent(String.self, forKey: .microphoneDeviceID)
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
