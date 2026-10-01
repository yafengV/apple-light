import AVFoundation
import CoreMedia
import XCTest
@testable import ShipiOS

final class RealtimeVoiceWireTests: XCTestCase {
  func testIndependentServiceWebSocketKeepsCredentialOutOfURL() throws {
    var config = ModelConfiguration()
    config.baseURL = "https://voice.example.com/v1"
    let request = try RealtimeVoiceWire.request(config: config,
      model: "custom-realtime", key: "test-secret")
    XCTAssertEqual(request.url?.absoluteString,
      "wss://voice.example.com/v1/realtime?model=custom-realtime")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-secret")
    XCTAssertFalse(try XCTUnwrap(request.url?.absoluteString).contains("test-secret"))

    config.baseURL = "http://localhost:1234/v1"
    XCTAssertEqual(try RealtimeVoiceWire.request(config: config,
      model: "test-model", key: nil).url?.scheme, "ws")
    config.baseURL = "http://outside.example/v1"
    XCTAssertThrowsError(try RealtimeVoiceWire.request(config: config,
      model: "test-model", key: nil))
  }

  func testSessionConfigurationAndEventParsing() throws {
    let data = try RealtimeVoiceWire.sessionUpdate(model: "test-model", voice: "marin")
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let session = try XCTUnwrap(object["session"] as? [String: Any])
    let audio = try XCTUnwrap(session["audio"] as? [String: Any])
    let input = try XCTUnwrap(audio["input"] as? [String: Any])
    XCTAssertEqual(object["type"] as? String, "session.update")
    XCTAssertEqual(session["output_modalities"] as? [String], ["audio"])
    XCTAssertEqual((input["format"] as? [String: Any])?["rate"] as? Int, 24_000)
    XCTAssertEqual((input["turn_detection"] as? [String: Any])?["type"] as? String,
      "semantic_vad")
    XCTAssertEqual(try RealtimeVoiceEvent.parse(Data(#"{"type":"session.created"}"#.utf8)),
      .sessionCreated)
    XCTAssertEqual(try RealtimeVoiceEvent.parse(Data(
      #"{"type":"response.output_audio_transcript.delta","delta":"Hello"}"#.utf8)),
      .assistantText("Hello"))
    XCTAssertEqual(try RealtimeVoiceEvent.parse(Data(
      #"{"type":"response.done","response":{"status":"completed"}}"#.utf8)),
      .responseDone("completed"))
    XCTAssertEqual(try RealtimeVoiceEvent.parse(Data(
      #"{"type":"response.output_audio.delta","delta":"AQIDBA=="}"#.utf8)),
      .assistantAudio(Data([1, 2, 3, 4])))
    XCTAssertThrowsError(try RealtimeVoiceEvent.parse(Data(
      #"{"type":"response.output_audio.delta","delta":"AQID"}"#.utf8)))
    let appended = try XCTUnwrap(JSONSerialization.jsonObject(with:
      RealtimeVoiceWire.audioAppend(Data([1, 2]))) as? [String: String])
    XCTAssertEqual(appended["type"], "input_audio_buffer.append")
    XCTAssertEqual(appended["audio"], "AQI=")
  }

  func testPCMEncoderResamplesAcrossBuffersAndUsesLittleEndian() throws {
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let first = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
    first.frameLength = 480
    let second = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
    second.frameLength = 480
    for index in 0..<480 {
      first.floatChannelData?[0][index] = 0.5
      second.floatChannelData?[0][index] = 0.5
    }
    let encoder = RealtimePCMEncoder()
    let a = try XCTUnwrap(encoder.encode(first))
    let b = try XCTUnwrap(encoder.encode(second))
    XCTAssertEqual(a.count + b.count, 960)
    XCTAssertEqual(Array(a.prefix(2)), [0x00, 0x40])
    XCTAssertEqual(Array(b.prefix(2)), [0x00, 0x40])
  }

  func testPCMEncoderAcceptsInterleavedStereoAndNonFiniteSample() throws {
    let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16,
      sampleRate: 24_000, channels: 2, interleaved: true))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
    buffer.frameLength = 4
    let samples = try XCTUnwrap(buffer.int16ChannelData)
    for index in 0..<4 {
      samples[0][index * 2] = 16_384
      samples[0][index * 2 + 1] = 0
    }
    let encoded = try XCTUnwrap(RealtimePCMEncoder().encode(buffer))
    XCTAssertEqual(encoded.count, 8)
    XCTAssertEqual(Array(encoded.prefix(2)), [0x00, 0x20])

    let floatFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000,
      channels: 1))
    let nonFinite = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: 2))
    nonFinite.frameLength = 2
    nonFinite.floatChannelData?[0][0] = .nan
    nonFinite.floatChannelData?[0][1] = .nan
    XCTAssertEqual(RealtimePCMEncoder().encode(nonFinite), Data([0, 0, 0, 0]))
  }

  func testPCMEncoderAcceptsCaptureSampleBuffer() throws {
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    var stream = format.streamDescription.pointee
    var description: CMAudioFormatDescription?
    XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
      asbd: &stream, layoutSize: 0, layout: nil, magicCookieSize: 0,
      magicCookie: nil, extensions: nil, formatDescriptionOut: &description), noErr)
    let samples = Array(repeating: Float(0.5), count: 480)
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
    let encoded = try XCTUnwrap(RealtimePCMEncoder().encode(XCTUnwrap(sample)))
    XCTAssertEqual(encoded.count, 480)
    XCTAssertEqual(Array(encoded.prefix(2)), [0x00, 0x40])
  }
}
