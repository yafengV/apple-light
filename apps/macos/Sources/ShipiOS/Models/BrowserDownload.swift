import Foundation

enum BrowserDownloadDestination {
  case save(URL)
  case cancel
  case failure(String)
}
typealias BrowserDownloadDestinationChooser = (URL, String, @escaping (BrowserDownloadDestination) -> Void) -> Void

enum BrowserDownloadStatus: String, Codable, Sendable {
  case preparing
  case downloading
  case finished
  case failed
  case cancelled

  var title: String {
    switch self {
    case .preparing: "正在准备"
    case .downloading: "正在下载"
    case .finished: "已完成"
    case .failed: "失败"
    case .cancelled: "已取消"
    }
  }
}

struct BrowserDownloadRecord: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let sourceURL: String
  var filename: String
  var destinationPath: String?
  var status: BrowserDownloadStatus
  var byteCount: Int64?
  var message: String?
  var createdAt = Date()
}

struct BrowserDownloadPreferences: Codable, Equatable, Sendable {
  var directory: String?
  var askWhereToSave = false
}

enum BrowserDownloadEvent: Sendable {
  case started(id: UUID, sourceURL: String, filename: String)
  case destination(id: UUID, url: URL)
  case progress(id: UUID, fraction: Double)
  case finished(id: UUID)
  case failed(id: UUID, message: String)
  case cancelled(id: UUID)
}
