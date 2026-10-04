import AppKit

/// Monochrome 16-point geometry for the four comment menu controls.
@MainActor enum PullRequestCommentMenuArtwork {
  private static let geometry: [String: [(String, Bool)]] = [
    "edit": [
      ("M9.41506 2.54535C10.5566 1.516 12.2884 1.57105 13.3399 2.64105C14.4597 3.72222 14.4959 5.5405 13.3467 6.68988L7.75588 12.2797C7.18583 12.8809 6.45561 13.2881 5.6924 13.4653H5.69045L2.59767 14.1762L2.5967 14.1743C2.4644 14.2058 2.19674 14.2328 1.98342 14.02C1.76937 13.8062 1.79632 13.5371 1.82814 13.4047L2.5381 10.3188C2.71723 9.5224 3.12639 8.8269 3.68752 8.26703L9.30568 2.64887L9.41506 2.54535ZM4.4297 9.01019C3.99658 9.44234 3.69398 9.96492 3.56252 10.5512L3.56154 10.5541L2.99513 13.0063L5.45607 12.4418C6.02206 12.3102 6.56957 12.0068 6.99513 11.558L7.00392 11.5483L11.5254 7.02582L8.96877 4.46918L4.4297 9.01019ZM12.5986 3.38422C11.9258 2.69135 10.7787 2.66298 10.0479 3.39203L10.0469 3.39105L9.71193 3.72602L12.2686 6.28266L12.6045 5.94769C13.3406 5.21146 13.3067 4.06829 12.6113 3.39691L12.5986 3.38422Z", true)
    ],
    "quote": [
      ("M2.39966 3.25C2.70341 3.25 2.94946 3.49605 2.94946 3.7998V7.5293C2.94946 8.03731 3.36141 8.44907 3.86938 8.44922H12.2717L10.011 6.18848C9.79632 5.97372 9.79635 5.6259 10.011 5.41113C10.2257 5.19637 10.5735 5.19642 10.7883 5.41113L13.9182 8.54004C14.1717 8.79376 14.1716 9.20517 13.9182 9.45898L10.7883 12.5889C10.5736 12.8032 10.2257 12.8032 10.011 12.5889C9.79632 12.3741 9.79635 12.0253 10.011 11.8105L12.2708 9.5498H3.86938C2.7539 9.54966 1.84985 8.64482 1.84985 7.5293V3.7998C1.84985 3.49605 2.0959 3.25 2.39966 3.25Z", false)
    ],
    "delete": [
      ("M6.66724 6.80762C6.95696 6.80788 7.19263 7.04322 7.19263 7.33301V10.6729C7.19256 10.9626 6.95692 11.197 6.66724 11.1973C6.37733 11.1973 6.14192 10.9627 6.14185 10.6729V7.33301C6.14185 7.04306 6.37729 6.80762 6.66724 6.80762Z", false),
      ("M9.33325 6.80762C9.6232 6.80762 9.85864 7.04306 9.85864 7.33301V10.6729C9.85857 10.9627 9.62316 11.1973 9.33325 11.1973C9.04335 11.1973 8.80793 10.9627 8.80786 10.6729V7.33301C8.80786 7.04306 9.0433 6.80762 9.33325 6.80762Z", false),
      ("M8.00024 1.25391C9.66003 1.25407 11.0236 2.52186 11.177 4.1416H13.6663C13.9562 4.1416 14.1917 4.37704 14.1917 4.66699C14.1914 4.95672 13.956 5.19238 13.6663 5.19238H13.1692L12.6995 12.1787C12.6105 13.5045 11.5096 14.5349 10.1809 14.5352H5.8313C4.50407 14.535 3.40273 13.5068 3.31177 12.1826L2.83228 5.19238H2.33325C2.04347 5.19238 1.80813 4.95672 1.80786 4.66699C1.80786 4.37704 2.0433 4.1416 2.33325 4.1416H4.82251C4.976 2.52175 6.34031 1.25391 8.00024 1.25391ZM4.35962 12.1104C4.41275 12.8838 5.05604 13.4842 5.8313 13.4844H10.1809C10.957 13.4841 11.6006 12.8828 11.6526 12.1084L12.1165 5.19238H3.88403L4.35962 12.1104ZM8.00024 2.30469C6.92101 2.30469 6.03114 3.10331 5.88306 4.1416H10.1174C9.96932 3.10342 9.07933 2.30485 8.00024 2.30469Z", true)
    ],
    "ellipsis": [
      ("M3.33362 6.80811C3.99161 6.80828 4.52502 7.34246 4.52502 8.00049C4.52485 8.65837 3.9915 9.19172 3.33362 9.19189C2.67559 9.19189 2.14141 8.65848 2.14124 8.00049C2.14124 7.34235 2.67548 6.80811 3.33362 6.80811Z", false),
      ("M8.00061 6.80811C8.65849 6.80841 9.19202 7.34254 9.19202 8.00049C9.19184 8.65829 8.65838 9.19159 8.00061 9.19189C7.34258 9.19189 6.8084 8.65848 6.80823 8.00049C6.80823 7.34235 7.34247 6.80811 8.00061 6.80811Z", false),
      ("M12.6666 6.80811C13.3246 6.80828 13.858 7.34246 13.858 8.00049C13.8579 8.65837 13.3245 9.19172 12.6666 9.19189C12.0088 9.1917 11.4744 8.65836 11.4742 8.00049C11.4742 7.34247 12.0087 6.8083 12.6666 6.80811Z", false)
    ]
  ]
  private static let tokens = try! NSRegularExpression(pattern: "[MCLHVZ]|[-+]?(?:[0-9]*\\.[0-9]+|[0-9]+)(?:[eE][-+]?[0-9]+)?")
  private static let paths: [String: [NSBezierPath]] = geometry.mapValues { values in
    values.compactMap { source, evenOdd in
      guard let path = path(source) else { return nil }
      path.windingRule = evenOdd ? .evenOdd : .nonZero; return path
    }
  }
  static func bounds(_ name: String) -> NSRect? {
    guard let paths = paths[name], let first = paths.first else { return nil }
    return paths.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
  }
  static func draw(_ name: String, in rect: NSRect, color: NSColor, flipped: Bool) {
    guard let paths = paths[name] else { return }
    NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
    let transform = NSAffineTransform()
    transform.translateX(by: rect.minX, yBy: flipped ? rect.minY : rect.maxY)
    transform.scaleX(by: rect.width / 16, yBy: (flipped ? 1 : -1) * rect.height / 16)
    transform.concat(); color.setFill(); paths.forEach { $0.fill() }
  }
  private static func path(_ source: String) -> NSBezierPath? {
    let source = source as NSString
    let words = tokens.matches(in: source as String, range: .init(location: 0, length: source.length)).map { source.substring(with: $0.range) }
    let path = NSBezierPath(); var index = 0, command = "", point = NSPoint.zero, start = NSPoint.zero
    while index < words.count {
      if Double(words[index]) == nil { command = words[index]; index += 1 }
      if command == "Z" { path.close(); point = start; command = ""; continue }
      let count: Int
      switch command { case "M", "L": count = 2; case "H", "V": count = 1; case "C": count = 6; default: return nil }
      guard index + count <= words.count else { return nil }
      let values = words[index..<(index + count)].compactMap { Double($0) }.map { CGFloat($0) }
      guard values.count == count else { return nil }; index += count
      switch command {
      case "M": point = .init(x: values[0], y: values[1]); start = point; path.move(to: point); command = "L"
      case "L": point = .init(x: values[0], y: values[1]); path.line(to: point)
      case "H": point.x = values[0]; path.line(to: point)
      case "V": point.y = values[0]; path.line(to: point)
      case "C":
        point = .init(x: values[4], y: values[5])
        path.curve(to: point, controlPoint1: .init(x: values[0], y: values[1]), controlPoint2: .init(x: values[2], y: values[3]))
      default: return nil
      }
    }
    return path
  }
}
