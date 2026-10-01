import Foundation

struct VoicePreferences: Codable, Equatable {
  var dictationLocaleIdentifier: String?
  var dictationDictionary: [String] = []

  init(dictationLocaleIdentifier: String? = nil, dictationDictionary: [String] = []) {
    self.dictationLocaleIdentifier = dictationLocaleIdentifier
    self.dictationDictionary = dictationDictionary
    normalize()
  }

  private enum CodingKeys: CodingKey { case dictationLocaleIdentifier, dictationDictionary }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    dictationLocaleIdentifier = try values.decodeIfPresent(String.self, forKey: .dictationLocaleIdentifier)
    dictationDictionary = try values.decodeIfPresent([String].self, forKey: .dictationDictionary) ?? []
    normalize()
  }

  mutating func normalize() {
    dictationLocaleIdentifier = dictationLocaleIdentifier?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if dictationLocaleIdentifier?.isEmpty == true { dictationLocaleIdentifier = nil }
    dictationDictionary = dictationDictionary.compactMap { entry in
      let word = entry.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !word.isEmpty else { return nil }
      return word
    }
  }
}
