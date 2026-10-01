import AVFoundation
import CoreMedia
import XCTest
@testable import ShipiOS

final class SpeechAudioLevelTests: XCTestCase {
  func testPCMBufferLevelUsesActualSamples() throws {
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
    buffer.frameLength = 128
    let data = try XCTUnwrap(buffer.floatChannelData)
    for index in 0..<128 { data[0][index] = 0 }
    XCTAssertEqual(try XCTUnwrap(SpeechAudioLevel.value(buffer)), 0, accuracy: 0.001)
    for index in 0..<128 { data[0][index] = 0.1 }
    XCTAssertGreaterThan(try XCTUnwrap(SpeechAudioLevel.value(buffer)), 0.5)
    for index in 0..<128 { data[0][index] = 1 }
    XCTAssertEqual(try XCTUnwrap(SpeechAudioLevel.value(buffer)), 1, accuracy: 0.001)
  }

  func testIntegerPCMBufferLevel() throws {
    let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16,
      sampleRate: 48_000, channels: 1, interleaved: false))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
    buffer.frameLength = 64
    let data = try XCTUnwrap(buffer.int16ChannelData)
    for index in 0..<64 { data[0][index] = 16_384 }
    XCTAssertGreaterThan(try XCTUnwrap(SpeechAudioLevel.value(buffer)), 0.8)
  }

  func testCaptureSampleBufferLevelUsesPCMBytes() throws {
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    var stream = format.streamDescription.pointee
    var description: CMAudioFormatDescription?
    XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
      asbd: &stream, layoutSize: 0, layout: nil, magicCookieSize: 0,
      magicCookie: nil, extensions: nil, formatDescriptionOut: &description), noErr)
    let samples = Array(repeating: Float(0.1), count: 128)
    let byteCount = samples.count * MemoryLayout<Float>.size
    var block: CMBlockBuffer?
    XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
      memoryBlock: nil, blockLength: byteCount, blockAllocator: kCFAllocatorDefault,
      customBlockSource: nil, offsetToData: 0, dataLength: byteCount,
      flags: 0, blockBufferOut: &block), noErr)
    let dataBlock = try XCTUnwrap(block)
    let copyStatus = samples.withUnsafeBytes { bytes in
      CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: dataBlock,
        offsetIntoDestination: 0, dataLength: byteCount)
    }
    XCTAssertEqual(copyStatus, noErr)
    var sampleBuffer: CMSampleBuffer?
    XCTAssertEqual(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
      allocator: kCFAllocatorDefault, dataBuffer: dataBlock,
      formatDescription: try XCTUnwrap(description), sampleCount: samples.count,
      presentationTimeStamp: .zero, packetDescriptions: nil,
      sampleBufferOut: &sampleBuffer), noErr)
    XCTAssertGreaterThan(try XCTUnwrap(SpeechAudioLevel.value(
      XCTUnwrap(sampleBuffer))), 0.5)
  }

  func testInvalidEnergyIsIgnored() {
    XCTAssertNil(SpeechAudioLevel.normalized(squares: .nan, count: 100))
    XCTAssertNil(SpeechAudioLevel.normalized(squares: -1, count: 100))
    XCTAssertNil(SpeechAudioLevel.normalized(squares: 1, count: 0))
  }
}
