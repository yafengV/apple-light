import AVFoundation
import CoreMedia

/// Writes captured PCM off the audio callback thread, in the same order as Speech receives it.
final class VoiceRecordingCapture: @unchecked Sendable {
  private let url: URL
  private let queue = DispatchQueue(label: "dev.shipios.dictation.recording")
  private let lock = NSLock()
  private var ended = false
  private var inputEnded = false
  private var pendingCompletion: (@Sendable (Int64, Error?) -> Void)?
  private var file: AVAudioFile?
  private var error: Error?

  init(url: URL) { self.url = url }

  func append(_ source: AVAudioPCMBuffer) {
    guard let copy = Self.copy(source) else { return }
    enqueue(copy)
  }

  func append(_ sample: CMSampleBuffer) {
    guard let description = CMSampleBufferGetFormatDescription(sample),
      let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description),
      basic.pointee.mFormatID == kAudioFormatLinearPCM,
      let format = AVAudioFormat(streamDescription: basic) else { return }
    let frames = CMSampleBufferGetNumSamples(sample)
    guard frames > 0, let copy = AVAudioPCMBuffer(pcmFormat: format,
      frameCapacity: AVAudioFrameCount(frames)) else { return }
    copy.frameLength = AVAudioFrameCount(frames)
    let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0,
      frameCount: Int32(frames), into: copy.mutableAudioBufferList)
    guard status == noErr else { return }
    enqueue(copy)
  }

  func finish(_ completion: @escaping @Sendable (Int64, Error?) -> Void) {
    lock.lock()
    guard !ended, pendingCompletion == nil else { lock.unlock(); return }
    pendingCompletion = completion
    finalizeIfReady()
    lock.unlock()
  }

  func markInputEnded() {
    lock.lock()
    inputEnded = true
    finalizeIfReady()
    lock.unlock()
  }

  private func enqueue(_ buffer: AVAudioPCMBuffer) {
    lock.lock()
    guard !ended else { lock.unlock(); return }
    queue.async {
      guard self.error == nil else { return }
      do {
        if self.file == nil {
          self.file = try AVAudioFile(forWriting: self.url, settings: buffer.format.settings,
            commonFormat: buffer.format.commonFormat, interleaved: buffer.format.isInterleaved)
          try? FileManager.default.setAttributes([.posixPermissions: 0o600],
            ofItemAtPath: self.url.path)
        }
        try self.file?.write(from: buffer)
      } catch {
        self.error = error
      }
    }
    lock.unlock()
  }

  /// Called with the lock held; the final queue item follows every accepted sample.
  private func finalizeIfReady() {
    guard inputEnded, let completion = pendingCompletion, !ended else { return }
    ended = true
    pendingCompletion = nil
    queue.async {
      self.file = nil
      let attributes = try? FileManager.default.attributesOfItem(atPath: self.url.path)
      let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
      completion(size, self.error)
    }
  }

  private static func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard source.frameLength > 0,
      let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else {
      return nil
    }
    copy.frameLength = source.frameLength
    let original = UnsafeMutableAudioBufferListPointer(
      UnsafeMutablePointer(mutating: source.audioBufferList))
    let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
    guard original.count == destination.count else { return nil }
    for index in original.indices {
      guard let from = original[index].mData, let to = destination[index].mData,
        original[index].mDataByteSize <= destination[index].mDataByteSize else { return nil }
      memcpy(to, from, Int(original[index].mDataByteSize))
      destination[index].mDataByteSize = original[index].mDataByteSize
    }
    return copy
  }
}
