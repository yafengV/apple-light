import AVFoundation
import CoreMedia

enum SpeechAudioLevel {
  static func value(_ buffer: AVAudioPCMBuffer) -> Double? {
    let frames = Int(buffer.frameLength)
    let channels = Int(buffer.format.channelCount)
    guard frames > 0, channels > 0 else { return nil }
    let step = max(1, frames / 512)
    let sampleStride = Int(buffer.stride)
    var squares = 0.0
    var count = 0
    for channel in 0..<channels {
      if let data = buffer.floatChannelData {
        for frame in stride(from: 0, to: frames, by: step) {
          let value = Double(data[channel][frame * sampleStride])
          squares += value * value
          count += 1
        }
      } else if let data = buffer.int16ChannelData {
        for frame in stride(from: 0, to: frames, by: step) {
          let value = Double(data[channel][frame * sampleStride]) / 32_768
          squares += value * value
          count += 1
        }
      } else if let data = buffer.int32ChannelData {
        for frame in stride(from: 0, to: frames, by: step) {
          let value = Double(data[channel][frame * sampleStride]) / 2_147_483_648
          squares += value * value
          count += 1
        }
      } else { return nil }
    }
    return normalized(squares: squares, count: count)
  }

  static func value(_ sampleBuffer: CMSampleBuffer) -> Double? {
    guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
      let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
      format.mFormatID == kAudioFormatLinearPCM,
      format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 else { return nil }
    var needed = 0
    _ = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer,
      bufferListSizeNeededOut: &needed, bufferListOut: nil, bufferListSize: 0,
      blockBufferAllocator: kCFAllocatorDefault,
      blockBufferMemoryAllocator: kCFAllocatorDefault,
      flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
      blockBufferOut: nil)
    guard needed >= MemoryLayout<AudioBufferList>.size else { return nil }
    let memory = UnsafeMutableRawPointer.allocate(byteCount: needed,
      alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { memory.deallocate() }
    let list = memory.bindMemory(to: AudioBufferList.self, capacity: 1)
    var block: CMBlockBuffer?
    guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer,
      bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: needed,
      blockBufferAllocator: kCFAllocatorDefault,
      blockBufferMemoryAllocator: kCFAllocatorDefault,
      flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
      blockBufferOut: &block) == noErr else { return nil }
    var squares = 0.0
    var count = 0
    for audioBuffer in UnsafeMutableAudioBufferListPointer(list) {
      guard let pointer = audioBuffer.mData else { continue }
      let bits = Int(format.mBitsPerChannel)
      guard bits == 16 || bits == 32 else { return nil }
      let sampleCount = Int(audioBuffer.mDataByteSize) / (bits / 8)
      let step = max(1, sampleCount / 512)
      if bits == 32 && format.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
        let samples = pointer.assumingMemoryBound(to: Float.self)
        for index in stride(from: 0, to: sampleCount, by: step) {
          let value = Double(samples[index])
          squares += value * value
          count += 1
        }
      } else if bits == 16 && format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 {
        let samples = pointer.assumingMemoryBound(to: Int16.self)
        for index in stride(from: 0, to: sampleCount, by: step) {
          let value = Double(samples[index]) / 32_768
          squares += value * value
          count += 1
        }
      } else if bits == 32 && format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 {
        let samples = pointer.assumingMemoryBound(to: Int32.self)
        for index in stride(from: 0, to: sampleCount, by: step) {
          let value = Double(samples[index]) / 2_147_483_648
          squares += value * value
          count += 1
        }
      } else { return nil }
    }
    withExtendedLifetime(block) {}
    return normalized(squares: squares, count: count)
  }

  static func normalized(squares: Double, count: Int) -> Double? {
    guard count > 0, squares.isFinite, squares >= 0 else { return nil }
    let rms = sqrt(squares / Double(count))
    guard rms.isFinite else { return nil }
    let decibels = 20 * log10(max(rms, 0.000_001))
    return min(1, max(0, (decibels + 60) / 50))
  }
}

/// Limits observable UI updates while leaving Speech's full-rate audio stream intact.
final class SpeechAudioLevelMeter: @unchecked Sendable {
  private let lock = NSLock()
  private var lastUpdate: TimeInterval = 0
  private let onLevel: @Sendable (Double) -> Void

  init(onLevel: @escaping @Sendable (Double) -> Void) { self.onLevel = onLevel }

  func append(_ buffer: AVAudioPCMBuffer) {
    if let level = SpeechAudioLevel.value(buffer) { publish(level) }
  }

  func append(_ buffer: CMSampleBuffer) {
    if let level = SpeechAudioLevel.value(buffer) { publish(level) }
  }

  private func publish(_ level: Double) {
    let now = ProcessInfo.processInfo.systemUptime
    lock.lock()
    let shouldPublish = now - lastUpdate >= 0.05
    if shouldPublish { lastUpdate = now }
    lock.unlock()
    if shouldPublish { onLevel(level) }
  }
}
