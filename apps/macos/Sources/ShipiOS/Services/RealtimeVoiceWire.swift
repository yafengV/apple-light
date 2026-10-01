import AVFoundation
import CoreMedia
import Foundation

struct RealtimeVoiceWire {
  static let sampleRate = 24_000.0

  static func request(config: ModelConfiguration, model: String, key: String?) throws -> URLRequest {
    let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !model.isEmpty else { throw AgentFailure(message: "请在语音设置中填写实时语音模型 ID。") }
    guard var components = try URLComponents(url: config.endpoint("realtime"),
      resolvingAgainstBaseURL: false) else {
      throw AgentFailure(message: "无法生成语音服务连接地址。")
    }
    components.scheme = components.scheme == "https" ? "wss" : "ws"
    components.queryItems = [URLQueryItem(name: "model", value: model)]
    guard let url = components.url else {
      throw AgentFailure(message: "无法生成语音服务连接地址。")
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = 30
    if let key, !key.isEmpty {
      request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }
    return request
  }

  static func sessionUpdate(model: String, voice: String) throws -> Data {
    try json([
      "type": "session.update",
      "session": [
        "type": "realtime", "model": model, "output_modalities": ["audio"],
        "audio": [
          "input": [
            "format": ["type": "audio/pcm", "rate": 24_000],
            "turn_detection": ["type": "semantic_vad"],
          ],
          "output": [
            "format": ["type": "audio/pcm", "rate": 24_000], "voice": voice,
          ],
        ],
      ],
    ])
  }

  static func audioAppend(_ bytes: Data) throws -> Data {
    try json(["type": "input_audio_buffer.append", "audio": bytes.base64EncodedString()])
  }

  private static func json(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }
}

enum RealtimeVoiceEvent: Equatable {
  case sessionCreated, sessionUpdated, speechStarted, speechStopped, responseStarted
  case assistantAudio(Data), assistantText(String), userText(String)
  case responseDone(String), error(String), ignored

  static func parse(_ data: Data) throws -> Self {
    guard data.count <= 2_097_152,
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let type = object["type"] as? String else {
      throw AgentFailure(message: "语音服务返回了无效或过大的事件。")
    }
    switch type {
    case "session.created": return .sessionCreated
    case "session.updated": return .sessionUpdated
    case "input_audio_buffer.speech_started": return .speechStarted
    case "input_audio_buffer.speech_stopped": return .speechStopped
    case "response.created": return .responseStarted
    case "response.output_audio.delta":
      guard let value = object["delta"] as? String, value.utf8.count <= 1_398_104,
        let decoded = Data(base64Encoded: value), decoded.count <= 1_048_576,
        decoded.count % 2 == 0 else {
        throw AgentFailure(message: "语音服务返回了无效的音频片段。")
      }
      return .assistantAudio(decoded)
    case "response.output_audio_transcript.delta":
      return .assistantText(object["delta"] as? String ?? "")
    case "conversation.item.input_audio_transcription.completed":
      return .userText(object["transcript"] as? String ?? "")
    case "response.done":
      let response = object["response"] as? [String: Any]
      return .responseDone(response?["status"] as? String ?? "unknown")
    case "error":
      let error = object["error"] as? [String: Any]
      return .error(error?["message"] as? String ?? "语音服务返回错误。")
    default: return .ignored
    }
  }
}

/// Converts native microphone PCM to the Realtime API's mono, signed 16-bit, 24 kHz PCM.
final class RealtimePCMEncoder {
  private var sourceRate = 0.0
  private var sourceFrame = 0.0
  private var nextOutputTime = 0.0
  private var previous: Float?

  func encode(_ sample: CMSampleBuffer) -> Data? {
    guard let description = CMSampleBufferGetFormatDescription(sample),
      let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description),
      basic.pointee.mFormatID == kAudioFormatLinearPCM,
      basic.pointee.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
      let format = AVAudioFormat(streamDescription: basic) else { return nil }
    let frames = CMSampleBufferGetNumSamples(sample)
    guard frames > 0, frames <= 96_000,
      let buffer = AVAudioPCMBuffer(pcmFormat: format,
        frameCapacity: AVAudioFrameCount(frames)) else { return nil }
    buffer.frameLength = AVAudioFrameCount(frames)
    guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0,
      frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr else { return nil }
    return encode(buffer)
  }

  func encode(_ buffer: AVAudioPCMBuffer) -> Data? {
    let rate = buffer.format.sampleRate
    let frames = Int(buffer.frameLength)
    let channels = Int(buffer.format.channelCount)
    guard rate >= 8_000, rate <= 192_000, frames > 0, channels > 0,
      channels <= 8 else { return nil }
    if sourceRate != rate {
      sourceRate = rate
      sourceFrame = 0
      nextOutputTime = 0
      previous = nil
    }
    var output = Data(capacity: Int(Double(frames) * RealtimeVoiceWire.sampleRate / rate + 2) * 2)
    for frame in 0..<frames {
      var mixed = Float(0)
      for channel in 0..<channels {
        let plane = buffer.format.isInterleaved ? 0 : channel
        let offset = frame * Int(buffer.stride) + (buffer.format.isInterleaved ? channel : 0)
        if let data = buffer.floatChannelData {
          mixed += data[plane][offset]
        } else if let data = buffer.int16ChannelData {
          mixed += Float(data[plane][offset]) / 32_768
        } else if let data = buffer.int32ChannelData {
          mixed += Float(data[plane][offset]) / 2_147_483_648
        } else { return nil }
      }
      mixed /= Float(channels)
      if !mixed.isFinite { mixed = 0 }
      let currentTime = sourceFrame / rate
      if let previous {
        let priorTime = (sourceFrame - 1) / rate
        while nextOutputTime <= currentTime {
          let fraction = Swift.max(0, Swift.min(1,
            Float((nextOutputTime - priorTime) * rate)))
          let sample = Swift.max(-1, Swift.min(1, previous + (mixed - previous) * fraction))
          let integer = Int16((sample * 32_767).rounded())
          output.append(UInt8(truncatingIfNeeded: integer))
          output.append(UInt8(truncatingIfNeeded: integer >> 8))
          nextOutputTime += 1 / RealtimeVoiceWire.sampleRate
        }
      }
      previous = mixed
      sourceFrame += 1
    }
    return output
  }
}
