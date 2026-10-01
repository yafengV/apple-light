import AVFoundation
import Speech

/// Feeds one explicitly selected microphone into the on-device recognition request.
// Configuration completes before dispatch; session control and sample delivery use serial queues.
final class SpeechCaptureInput: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate,
  @unchecked Sendable {
  private let session = AVCaptureSession()
  private let output = AVCaptureAudioDataOutput()
  private let request: SFSpeechAudioBufferRecognitionRequest
  private let meter: SpeechAudioLevelMeter
  private let sessionQueue = DispatchQueue(label: "dev.shipios.dictation.session")
  private let sampleQueue = DispatchQueue(label: "dev.shipios.dictation.samples")

  init(device: AVCaptureDevice, request: SFSpeechAudioBufferRecognitionRequest,
    meter: SpeechAudioLevelMeter) throws {
    self.request = request
    self.meter = meter
    super.init()
    let input = try AVCaptureDeviceInput(device: device)
    session.beginConfiguration()
    defer { session.commitConfiguration() }
    guard session.canAddInput(input) else {
      throw AgentFailure(message: "所选麦克风不支持音频采集。")
    }
    session.addInput(input)
    guard session.canAddOutput(output) else {
      throw AgentFailure(message: "所选麦克风不支持音频采集。")
    }
    session.addOutput(output)
    // The Speech request accepts the device's native audio sample format.
    output.audioSettings = nil
    output.setSampleBufferDelegate(self, queue: sampleQueue)
  }

  func start() async -> Bool {
    await withCheckedContinuation { continuation in
      sessionQueue.async {
        self.session.startRunning()
        continuation.resume(returning: self.session.isRunning)
      }
    }
  }

  func stop() {
    sessionQueue.async {
      self.output.setSampleBufferDelegate(nil, queue: nil)
      if self.session.isRunning { self.session.stopRunning() }
      // All callbacks queued before teardown finish before Speech sees endAudio.
      self.sampleQueue.async { self.request.endAudio() }
    }
  }

  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection) {
    request.appendAudioSampleBuffer(sampleBuffer)
    meter.append(sampleBuffer)
  }
}
