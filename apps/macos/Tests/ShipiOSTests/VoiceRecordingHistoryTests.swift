import AVFoundation
import CoreMedia
import XCTest
@testable import ShipiOS

final class VoiceRecordingHistoryTests: XCTestCase {
  func testCapturedPCMIsWrittenAndReadableAfterInputDrains() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("recording.caf")
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
    buffer.frameLength = 128
    let samples = try XCTUnwrap(buffer.floatChannelData)
    for index in 0..<128 { samples[0][index] = 0.25 }
    let capture = VoiceRecordingCapture(url: path)
    capture.append(buffer)
    let finished = expectation(description: "recording flushed")
    capture.finish { size, error in
      XCTAssertNil(error)
      XCTAssertGreaterThan(size, 0)
      finished.fulfill()
    }
    capture.markInputEnded()
    wait(for: [finished], timeout: 5)
    let permissions = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions]
      as? NSNumber
    XCTAssertEqual(permissions?.intValue, 0o600)
    let file = try AVAudioFile(forReading: path)
    let restored = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
      frameCapacity: 128))
    try file.read(into: restored)
    XCTAssertEqual(restored.frameLength, 128)
    XCTAssertEqual(try XCTUnwrap(restored.floatChannelData)[0][0], 0.25, accuracy: 0.001)
  }

  func testCapturedCMSampleBufferIsWrittenAndReadable() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("selected.caf")
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    var stream = format.streamDescription.pointee
    var description: CMAudioFormatDescription?
    XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
      asbd: &stream, layoutSize: 0, layout: nil, magicCookieSize: 0,
      magicCookie: nil, extensions: nil, formatDescriptionOut: &description), noErr)
    let samples = Array(repeating: Float(0.4), count: 128)
    let byteCount = samples.count * MemoryLayout<Float>.size
    var block: CMBlockBuffer?
    XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
      memoryBlock: nil, blockLength: byteCount, blockAllocator: kCFAllocatorDefault,
      customBlockSource: nil, offsetToData: 0, dataLength: byteCount,
      flags: 0, blockBufferOut: &block), noErr)
    let dataBlock = try XCTUnwrap(block)
    XCTAssertEqual(samples.withUnsafeBytes { bytes in
      CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: dataBlock,
        offsetIntoDestination: 0, dataLength: byteCount)
    }, noErr)
    var sample: CMSampleBuffer?
    XCTAssertEqual(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
      allocator: kCFAllocatorDefault, dataBuffer: dataBlock,
      formatDescription: try XCTUnwrap(description), sampleCount: samples.count,
      presentationTimeStamp: .zero, packetDescriptions: nil,
      sampleBufferOut: &sample), noErr)
    let capture = VoiceRecordingCapture(url: path)
    capture.append(try XCTUnwrap(sample))
    let finished = expectation(description: "selected device flushed")
    capture.finish { size, error in
      XCTAssertNil(error)
      XCTAssertGreaterThan(size, 0)
      finished.fulfill()
    }
    capture.markInputEnded()
    wait(for: [finished], timeout: 5)
    let file = try AVAudioFile(forReading: path)
    let restored = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
      frameCapacity: 128))
    try file.read(into: restored)
    XCTAssertEqual(restored.frameLength, 128)
    XCTAssertEqual(try XCTUnwrap(restored.floatChannelData)[0][0], 0.4, accuracy: 0.001)
  }

  func testIntegerPCMIsWrittenAndReadable() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("integer.caf")
    let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16,
      sampleRate: 48_000, channels: 1, interleaved: false))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
    buffer.frameLength = 64
    let samples = try XCTUnwrap(buffer.int16ChannelData)
    for index in 0..<64 { samples[0][index] = 12_345 }
    let capture = VoiceRecordingCapture(url: path)
    capture.append(buffer)
    let finished = expectation(description: "integer PCM flushed")
    capture.finish { size, error in
      XCTAssertNil(error)
      XCTAssertGreaterThan(size, 0)
      finished.fulfill()
    }
    capture.markInputEnded()
    wait(for: [finished], timeout: 5)
    let file = try AVAudioFile(forReading: path, commonFormat: .pcmFormatInt16,
      interleaved: false)
    let restored = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
      frameCapacity: 64))
    try file.read(into: restored)
    XCTAssertEqual(restored.frameLength, 64)
    XCTAssertEqual(try XCTUnwrap(restored.int16ChannelData)[0][0], 12_345)
  }

  @MainActor func testHistoryRecoversInterruptedRecordingAndDeletesSavedItem() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let history = VoiceRecordingHistory(dataRoot: root)
    let (id, _) = try XCTUnwrap(history.begin())
    XCTAssertEqual(history.recordings.first?.status, .recording)
    let directory = root.appendingPathComponent("VoiceRecordings")
    let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    let directoryPermissions = directoryAttributes[.posixPermissions] as? NSNumber
    XCTAssertEqual(directoryPermissions?.intValue, 0o700)
    let restored = VoiceRecordingHistory(dataRoot: root)
    XCTAssertEqual(restored.recordings.first?.id, id)
    XCTAssertEqual(restored.recordings.first?.status, .interrupted)
    restored.finish(id: id, text: "重新找回的文本", cancelled: false,
      sizeBytes: 0, recordingError: nil)
    XCTAssertEqual(restored.recordings.first?.text, "重新找回的文本")
    try restored.delete(id)
    XCTAssertTrue(restored.recordings.isEmpty)
    XCTAssertTrue(VoiceRecordingHistory(dataRoot: root).recordings.isEmpty)
  }

  @MainActor func testHistoryKeepsOnlyLastTwentyRecordings() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let history = VoiceRecordingHistory(dataRoot: root)
    var first: UUID?
    for index in 0..<21 {
      let (id, _) = try XCTUnwrap(history.begin())
      if index == 0 { first = id }
    }
    XCTAssertEqual(history.recordings.count, 20)
    XCTAssertFalse(history.recordings.contains { $0.id == first })
    XCTAssertEqual(VoiceRecordingHistory(dataRoot: root).recordings.count, 20)
  }
}
