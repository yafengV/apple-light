import Foundation

enum AppearanceColorEditing {
  static func sanitized(_ input: String) -> String {
    let hex = input.uppercased().unicodeScalars.filter { (48...57).contains($0.value) || (65...70).contains($0.value) }
    return "#" + String(String.UnicodeScalarView(hex.prefix(6)))
  }
  static func parsed(_ input: String) -> String? {
    guard input.utf8.count == 7, input.first == "#",
      input.dropFirst().utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }) else { return nil }
    return input.lowercased()
  }
  static func readableInk(_ hex: String) -> AppearanceRGBA {
    guard hex.utf8.count == 7, hex.first == "#", AppearancePreferences.validHex(hex) != nil else { return .init(hex: "#101010") }
    let color = AppearanceRGBA(hex: hex)
    let brightness = (Double(color.red) * 0.2126 + Double(color.green) * 0.7152 + Double(color.blue) * 0.0722) / 255
    return brightness > 0.62 ? .init(hex: "#101010") : .white
  }
}

/// The reference picker rounds RGB-to-HSV components to integers, while dragging
/// keeps fractional HSV until the emitted hex value changes externally.
struct AppearanceHSV: Equatable {
  var hue: Double
  var saturation: Double
  var brightness: Double
  init(hue: Double, saturation: Double, brightness: Double) {
    self.hue = hue; self.saturation = saturation; self.brightness = brightness
  }
  init(hex: String) {
    let c = AppearanceRGBA(hex: hex), r = Double(c.red), g = Double(c.green), b = Double(c.blue)
    let maximum = max(r, g, b), delta = maximum - min(r, g, b)
    let sector = delta == 0 ? 0 : maximum == r ? (g - b) / delta : maximum == g ? 2 + (b - r) / delta : 4 + (r - g) / delta
    hue = Self.round(60 * (sector < 0 ? sector + 6 : sector))
    saturation = Self.round(maximum == 0 ? 0 : delta / maximum * 100)
    brightness = Self.round(maximum / 255 * 100)
  }
  private static func round(_ value: Double) -> Double { floor(value + 0.5) }
  var color: AppearanceRGBA {
    let h = hue / 360 * 6, s = saturation / 100, v = brightness / 100
    let sector = Int(floor(h)) % 6, low = v * (1 - s), falling = v * (1 - (h - floor(h)) * s), rising = v * (1 - (1 - h + floor(h)) * s)
    return .init(red: Int(Self.round(255 * [v, falling, low, low, rising, v][sector])),
      green: Int(Self.round(255 * [rising, v, v, falling, low, low][sector])),
      blue: Int(Self.round(255 * [low, low, rising, v, v, falling][sector])))
  }
  var hsl: [Double] {
    let combined = (200 - saturation) * brightness / 100
    return [Self.round(hue), Self.round(combined > 0 && combined < 200 ? saturation * brightness / 100 / (combined <= 100 ? combined : 200 - combined) * 100 : 0), Self.round(combined / 2)]
  }
  var pointerColor: AppearanceRGBA {
    let hsl = hsl, light = hsl[2] / 100, chroma = (1 - abs(2 * light - 1)) * hsl[1] / 100
    let h = hsl[0] / 60, secondary = chroma * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)), base = light - chroma / 2
    let values: [Double]
    switch Int(floor(h)) % 6 {
    case 0: values = [chroma, secondary, 0]
    case 1: values = [secondary, chroma, 0]
    case 2: values = [0, chroma, secondary]
    case 3: values = [0, secondary, chroma]
    case 4: values = [secondary, 0, chroma]
    default: values = [chroma, 0, secondary]
    }
    return .init(red: Int(Self.round((values[0] + base) * 255)), green: Int(Self.round((values[1] + base) * 255)), blue: Int(Self.round((values[2] + base) * 255)))
  }
  enum Axis { case color, hue }
  func moving(_ axis: Axis, left: Double, top: Double) -> Self {
    var value = self
    if axis == .hue { value.hue = Self.clamp(left, upper: 1) * 360 }
    else { value.saturation = Self.clamp(left, upper: 1) * 100; value.brightness = (1 - Self.clamp(top, upper: 1)) * 100 }
    return value
  }
  func stepping(_ axis: Axis, left: Double, top: Double) -> Self {
    var value = self
    if axis == .hue { value.hue = Self.clamp(hue + 360 * left, upper: 360) }
    else { value.saturation = Self.clamp(saturation + 100 * left, upper: 100); value.brightness = Self.clamp(brightness - 100 * top, upper: 100) }
    return value
  }
  private static func clamp(_ value: Double, upper: Double) -> Double { min(upper, max(0, value)) }
}
