import Foundation

enum RunElapsedTime {
  static func title(createdAt: Double, updatedAt: Double) -> String? {
    let value = (updatedAt - createdAt) / 1000
    guard value.isFinite, value >= 0, value < Double(Int.max) else { return nil }
    let seconds = Int(value)
    if seconds >= 3600 {
      return "用时 \(seconds / 3600) 小时 \((seconds % 3600) / 60) 分钟"
    }
    if seconds >= 60 { return "用时 \(seconds / 60) 分钟 \(seconds % 60) 秒" }
    return "用时 \(seconds) 秒"
  }
}
