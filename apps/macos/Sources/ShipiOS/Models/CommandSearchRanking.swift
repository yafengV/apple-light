import Foundation

extension DesktopCommand {
  static func search(query: String) -> [DesktopCommand] {
    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return all }
    let matcher = DesktopFuzzyQuery(query)
    return all.enumerated().compactMap { index, command -> (Int, DesktopCommand, Int)? in
      let score = ([command.title] + command.searchAliases).compactMap { matcher.match($0)?.score }.max()
      return score.map { (index, command, $0) }
    }.sorted { $0.2 == $1.2 ? $0.0 < $1.0 : $0.2 > $1.2 }.map { $0.1 }
  }
}
