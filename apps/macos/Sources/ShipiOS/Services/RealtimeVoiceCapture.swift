import AVFoundation
import CoreMedia

/// Streams the chosen microphone without writing the voice conversation to disk.
final class RealtimeVoiceCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate,
  @unchecked Sendable {
  private let session = AVCaptureSession()
  private let output = AVCaptureAudioDataOutput()
  private let sampleQueue = DispatchQueue(label: "dev.shipios.voice.samples")
  private let sessionQueue = DispatchQueue(label: "dev.shipios.voice.session")
  private let stateLock = NSLock()
  private let encoder = RealtimePCMEncoder()
  private let onAudio: @Sendable (Data) -> Void
  private var muted = false

  init(device: AVCaptureDevice, onAudio: @escaping @Sendable (Data) -> Void) throws {
    self.onAudio = onAudio
    super.init()
    let input = try AVCaptureDeviceInput(device: device)
    session.beginConfiguration()
    defer { session.commitConfiguration() }
    guard session.canAddInput(input) else {
      throw AgentFailure(message: "所选麦克风不支持语音聊天。")
    }
    session.addInput(input)
    guard session.canAddOutput(output) else {
      throw AgentFailure(message: "无法从所选麦克风读取音频。")
    }
    session.addOutput(output)
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
    }
  }

  func setMuted(_ value: Bool) {
    stateLock.lock()
    muted = value
    stateLock.unlock()
  }

  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection) {
    stateLock.lock()
    let shouldSend = !muted
    stateLock.unlock()
    guard shouldSend, let bytes = encoder.encode(sampleBuffer), !bytes.isEmpty else { return }
    onAudio(bytes)
  }
}
