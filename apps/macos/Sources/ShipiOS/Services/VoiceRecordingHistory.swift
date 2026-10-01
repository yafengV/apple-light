import AVFoundation
import Observation
import Speech

struct VoiceRecording: Codable, Identifiable, Equatable {
  enum Status: String, Codable { case recording, saved, cancelled, interrupted }
  let id: UUID
  let createdAt: Date
  var status: Status
  var text: String
  var sizeBytes: Int64
}

@MainActor @Observable final class VoiceRecordingHistory {
  static let limit = 20
  private(set) var recordings: [VoiceRecording] = []
  private(set) var retryingID: UUID?
  private(set) var error: String?

  @ObservationIgnored private let directory: URL
  @ObservationIgnored private var recognizer: SFSpeechRecognizer?
  @ObservationIgnored private var retryTask: SFSpeechRecognitionTask?
  @ObservationIgnored private var retryTimeout: Task<Void, Never>?

  init(dataRoot: URL) {
    directory = dataRoot.appendingPathComponent("VoiceRecordings", isDirectory: true)
    if let data = try? Data(contentsOf: directory.appendingPathComponent("index.json")),
      let saved = try? JSONDecoder().decode([VoiceRecording].self, from: data) {
      recordings = Array(saved.sorted { $0.createdAt > $1.createdAt }.prefix(Self.limit))
      for index in recordings.indices {
        if recordings[index].status == .recording { recordings[index].status = .interrupted }
        recordings[index].sizeBytes = Self.fileSize(at: url(for: recordings[index].id))
      }
      persist()
    }
  }

  func begin() -> (UUID, VoiceRecordingCapture)? {
    var pendingID: UUID?
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try FileManager.default.setAttributes([.posixPermissions: 0o700],
        ofItemAtPath: directory.path)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      var mutableDirectory = directory
      try? mutableDirectory.setResourceValues(values)
      let id = UUID()
      pendingID = id
      recordings.insert(VoiceRecording(id: id, createdAt: .now, status: .recording,
        text: "", sizeBytes: 0), at: 0)
      trim()
      try persistThrowing()
      return (id, VoiceRecordingCapture(url: url(for: id)))
    } catch {
      if let pendingID { recordings.removeAll { $0.id == pendingID } }
      self.error = "无法保存听写录音：\(error.localizedDescription)"
      return nil
    }
  }

  func finish(id: UUID, text: String, cancelled: Bool, sizeBytes: Int64,
    recordingError: Error?) {
    guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
    recordings[index].text = text
    recordings[index].sizeBytes = sizeBytes
    recordings[index].status = recordingError == nil
      ? (cancelled ? .cancelled : .saved) : .interrupted
    if let recordingError {
      error = "录音保存中断：\(recordingError.localizedDescription)"
    }
    persist()
  }

  func delete(_ id: UUID) throws {
    guard let index = recordings.firstIndex(where: { $0.id == id }),
      recordings[index].status != .recording else { return }
    let path = url(for: id)
    if FileManager.default.fileExists(atPath: path.path) {
      try FileManager.default.removeItem(at: path)
    }
    recordings.remove(at: index)
    try persistThrowing()
  }

  func recordingURL(for id: UUID) -> URL? {
    guard let item = recordings.first(where: { $0.id == id }), item.sizeBytes > 0 else {
      return nil
    }
    let path = url(for: id)
    return FileManager.default.fileExists(atPath: path.path) ? path : nil
  }

  func retry(_ id: UUID, languageIdentifier: String?, dictionary: [String]) async {
    guard retryingID == nil,
      let item = recordings.first(where: { $0.id == id }), item.text.isEmpty,
      item.status != .recording, let path = recordingURL(for: id) else { return }
    error = nil
    retryingID = id
    let authorization = await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
    }
    guard retryingID == id else { return }
    guard authorization == .authorized else {
      failRetry("请在系统设置中允许 ShipiOS 使用语音识别。", id: id)
      return
    }
    let locale = languageIdentifier.map(Locale.init(identifier:)) ?? .current
    guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable,
      recognizer.supportsOnDeviceRecognition else {
      failRetry("当前语言的设备端语音识别不可用。", id: id)
      return
    }
    self.recognizer = recognizer
    let request = SFSpeechURLRecognitionRequest(url: path)
    request.requiresOnDeviceRecognition = true
    request.taskHint = .dictation
    request.contextualStrings = dictionary
    retryTask = recognizer.recognitionTask(with: request) { [weak self] result, failure in
      Task { @MainActor [weak self] in
        guard let self, self.retryingID == id else { return }
        if let failure {
          self.failRetry("重新转写失败：\(failure.localizedDescription)", id: id)
        } else if result?.isFinal == true {
          let text = result?.bestTranscription.formattedString ?? ""
          if let index = self.recordings.firstIndex(where: { $0.id == id }) {
            self.recordings[index].text = text
            self.recordings[index].status = .saved
            self.persist()
          }
          self.endRetry()
        }
      }
    }
    retryTimeout = Task { [weak self] in
      try? await Task.sleep(for: .seconds(90))
      guard !Task.isCancelled else { return }
      self?.failRetry("重新转写超时，请稍后重试。", id: id)
    }
  }

  func clearError() { error = nil }

  func report(_ failure: Error) { error = failure.localizedDescription }

  private func failRetry(_ message: String, id: UUID) {
    guard retryingID == id else { return }
    error = message
    endRetry()
  }

  private func endRetry() {
    retryTimeout?.cancel()
    retryTimeout = nil
    retryTask?.cancel()
    retryTask = nil
    recognizer = nil
    retryingID = nil
  }

  private func trim() {
    while recordings.count > Self.limit {
      let removed = recordings.removeLast()
      try? FileManager.default.removeItem(at: url(for: removed.id))
    }
  }

  private func url(for id: UUID) -> URL {
    directory.appendingPathComponent(id.uuidString + ".caf")
  }

  private func persist() {
    do { try persistThrowing() }
    catch { self.error = "无法保存录音记录：\(error.localizedDescription)" }
  }

  private func persistThrowing() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700],
      ofItemAtPath: directory.path)
    let data = try JSONEncoder().encode(recordings)
    let path = directory.appendingPathComponent("index.json")
    try data.write(to: path, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
  }

  private static func fileSize(at url: URL) -> Int64 {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
      .int64Value ?? 0
  }
}
