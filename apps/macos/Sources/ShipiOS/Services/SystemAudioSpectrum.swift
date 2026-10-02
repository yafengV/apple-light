import AppKit
import CoreAudio
import Observation

/// Frequency levels only. Captured PCM never leaves this process or reaches workspace storage.
enum SystemAudioSpectrumAnalysis {
  static let sampleCount = 1024
  static let bandCount = 64

  static func levels(samples: [Float], sampleRate: Double) -> [Double] {
    guard !samples.isEmpty, sampleRate > 0 else { return Array(repeating: 0, count: bandCount) }
    let count = sampleCount
    var real = Array(repeating: 0.0, count: count)
    var imaginary = real
    let start = max(0, samples.count - count)
    for index in 0..<min(count, samples.count) {
      let window = 0.5 - 0.5 * cos(2 * .pi * Double(index) / Double(count - 1))
      real[index] = Double(samples[start + index]) * window
    }
    var j = 0
    for index in 1..<count {
      var bit = count >> 1
      while j & bit != 0 { j ^= bit; bit >>= 1 }
      j ^= bit
      if index < j {
        real.swapAt(index, j)
        imaginary.swapAt(index, j)
      }
    }
    var length = 2
    while length <= count {
      let angle = -2 * Double.pi / Double(length)
      let baseReal = cos(angle), baseImaginary = sin(angle)
      for offset in stride(from: 0, to: count, by: length) {
        var twiddleReal = 1.0, twiddleImaginary = 0.0
        for step in 0..<(length / 2) {
          let first = offset + step, second = first + length / 2
          let shiftedReal = real[second] * twiddleReal - imaginary[second] * twiddleImaginary
          let shiftedImaginary = real[second] * twiddleImaginary + imaginary[second] * twiddleReal
          real[second] = real[first] - shiftedReal
          imaginary[second] = imaginary[first] - shiftedImaginary
          real[first] += shiftedReal
          imaginary[first] += shiftedImaginary
          let nextReal = twiddleReal * baseReal - twiddleImaginary * baseImaginary
          twiddleImaginary = twiddleReal * baseImaginary + twiddleImaginary * baseReal
          twiddleReal = nextReal
        }
      }
      length *= 2
    }
    let maxFrequency = min(18_000, sampleRate / 2)
    guard maxFrequency > 60 else { return Array(repeating: 0, count: bandCount) }
    return (0..<bandCount).map { band in
      let lowerFrequency = 60 * pow(maxFrequency / 60, Double(band) / Double(bandCount))
      let upperFrequency = 60 * pow(maxFrequency / 60, Double(band + 1) / Double(bandCount))
      let lower = max(1, min(count / 2, Int(lowerFrequency * Double(count) / sampleRate)))
      let upper = max(lower, min(count / 2, Int(ceil(upperFrequency * Double(count) / sampleRate))))
      var peak = 0.0
      for bin in lower...upper {
        peak = max(peak, hypot(real[bin], imaginary[bin]) * 2 / Double(count))
      }
      let decibels = 20 * log10(max(peak, 0.000_001))
      return min(1, max(0, (decibels + 70) / 60))
    }
  }
}

/// One private, non-mutating Core Audio process tap shared by every visible conversation rail.
protocol SystemAudioCapture: Sendable {
  func stop()
}

final class SystemAudioTap: SystemAudioCapture, @unchecked Sendable {
  private var tapID = AudioObjectID(kAudioObjectUnknown)
  private var aggregateID = AudioObjectID(kAudioObjectUnknown)
  private var ioProcID: AudioDeviceIOProcID?
  private let audioQueue = DispatchQueue(label: "dev.shipios.audio-spectrum.capture")
  private let analysisQueue = DispatchQueue(label: "dev.shipios.audio-spectrum.analysis")
  private let analysisGate = DispatchSemaphore(value: 1)
  private let onLevels: @Sendable ([Double]) -> Void
  private var lastAnalysis = 0.0

  init(onLevels: @escaping @Sendable ([Double]) -> Void) throws {
    self.onLevels = onLevels
    guard #available(macOS 14.2, *) else {
      throw AgentFailure(message: "音频可视化需要 macOS 14.2 或更新版本。")
    }
    let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
    description.name = "ShipiOS 音频可视化"
    description.isPrivate = true
    let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
    guard tapStatus == noErr else {
      throw AgentFailure(message: "无法启动系统音频录制（\(tapStatus)）。")
    }
    do {
      let composition: [String: Any] = [
        kAudioAggregateDeviceUIDKey: "dev.shipios.visualizer.\(UUID().uuidString)",
        kAudioAggregateDeviceNameKey: "ShipiOS 音频可视化",
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceSubDeviceListKey: [],
        kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString]],
      ]
      let aggregateStatus = AudioHardwareCreateAggregateDevice(composition as CFDictionary,
        &aggregateID)
      guard aggregateStatus == noErr else {
        throw AgentFailure(message: "无法创建系统音频输入（\(aggregateStatus)）。")
      }
      var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
      var format = AudioStreamBasicDescription()
      var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
      let formatStatus = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
      guard formatStatus == noErr, format.mFormatID == kAudioFormatLinearPCM else {
        throw AgentFailure(message: "系统音频格式不可用。")
      }
      let rate = format.mSampleRate
      let bits = format.mBitsPerChannel
      let flags = format.mFormatFlags
      let procStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID,
        audioQueue) { [weak self] _, input, _, _, _ in
          self?.receive(input, sampleRate: rate, bits: bits, flags: flags)
        }
      guard procStatus == noErr, ioProcID != nil else {
        throw AgentFailure(message: "无法读取系统音频输入（\(procStatus)）。")
      }
      let startStatus = AudioDeviceStart(aggregateID, ioProcID)
      guard startStatus == noErr else {
        throw AgentFailure(message: "无法开始系统音频录制（\(startStatus)）。")
      }
    } catch {
      stop()
      throw error
    }
  }

  private func receive(_ input: UnsafePointer<AudioBufferList>, sampleRate: Double,
    bits: UInt32, flags: AudioFormatFlags) {
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastAnalysis >= 0.05,
      analysisGate.wait(timeout: .now()) == .success else { return }
    lastAnalysis = now
    guard let buffer = UnsafeMutableAudioBufferListPointer(
      UnsafeMutablePointer(mutating: input)).first,
      let data = buffer.mData else {
      analysisGate.signal()
      return
    }
    let sampleCount = min(SystemAudioSpectrumAnalysis.sampleCount,
      Int(buffer.mDataByteSize) / max(1, Int(bits / 8)))
    guard sampleCount > 0 else { analysisGate.signal(); return }
    let samples: [Float]
    if bits == 32 && flags & kAudioFormatFlagIsFloat != 0 {
      let pointer = data.assumingMemoryBound(to: Float.self)
      samples = Array(UnsafeBufferPointer(start: pointer, count: sampleCount))
    } else if bits == 16 && flags & kAudioFormatFlagIsSignedInteger != 0 {
      let pointer = data.assumingMemoryBound(to: Int16.self)
      samples = (0..<sampleCount).map { Float(pointer[$0]) / 32_768 }
    } else {
      analysisGate.signal()
      return
    }
    analysisQueue.async { [analysisGate, onLevels] in
      onLevels(SystemAudioSpectrumAnalysis.levels(samples: samples, sampleRate: sampleRate))
      analysisGate.signal()
    }
  }

  func stop() {
    guard #available(macOS 14.2, *) else { return }
    if let ioProcID {
      AudioDeviceStop(aggregateID, ioProcID)
      AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
      self.ioProcID = nil
    }
    if aggregateID != kAudioObjectUnknown {
      AudioHardwareDestroyAggregateDevice(aggregateID)
      aggregateID = kAudioObjectUnknown
    }
    if tapID != kAudioObjectUnknown {
      AudioHardwareDestroyProcessTap(tapID)
      tapID = kAudioObjectUnknown
    }
  }

  deinit { stop() }
}

@MainActor @Observable final class SystemAudioVisualizer {
  static var isSupported: Bool {
    if #available(macOS 14.2, *) { true } else { false }
  }
  private(set) var levels: [Double] = []
  private(set) var error: String?
  @ObservationIgnored private var clients: Set<UUID> = []
  @ObservationIgnored private var capture: (any SystemAudioCapture)?
  @ObservationIgnored private var starting: Task<any SystemAudioCapture, Error>?
  @ObservationIgnored private var stopping: Task<Void, Never>?
  @ObservationIgnored private var decayTask: Task<Void, Never>?
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private let makeCapture:
    @Sendable (@escaping @Sendable ([Double]) -> Void) throws -> any SystemAudioCapture
  var hasClients: Bool { !clients.isEmpty }

  init(makeCapture: @escaping @Sendable (@escaping @Sendable ([Double]) -> Void) throws
    -> any SystemAudioCapture = { try SystemAudioTap(onLevels: $0) }) {
    self.makeCapture = makeCapture
  }

  func attach() -> UUID {
    let id = UUID()
    clients.insert(id)
    if Self.isSupported && NSApp.isActive {
      Task { try? await ensureStarted() }
    }
    return id
  }

  func resumeIfNeeded() {
    guard Self.isSupported, !clients.isEmpty, NSApp.isActive else { return }
    Task { try? await ensureStarted() }
  }

  func detach(_ id: UUID) {
    clients.remove(id)
    if clients.isEmpty { stop() }
  }

  func ensureStarted() async throws {
    if let stopping {
      await stopping.value
      self.stopping = nil
    }
    if capture != nil { return }
    let expected = generation
    let task: Task<any SystemAudioCapture, Error>
    if let starting { task = starting }
    else {
      let factory = makeCapture
      task = Task.detached(priority: .userInitiated) { [weak self] in
        try factory { [weak self] levels in
          Task { @MainActor [weak self] in self?.publish(levels) }
        }
      }
      starting = task
    }
    do {
      let result = try await task.value
      guard generation == expected else { throw CancellationError() }
      if capture == nil {
        capture = result
        starting = nil
        error = nil
      }
    } catch {
      if generation == expected {
        starting = nil
        self.error = error.localizedDescription
      }
      throw error
    }
  }

  func stop() {
    generation &+= 1
    if let starting {
      starting.cancel()
      stopping = Task.detached {
        if let result = try? await starting.value { result.stop() }
      }
    }
    starting = nil
    decayTask?.cancel()
    decayTask = nil
    let previous = capture
    capture = nil
    levels = []
    previous?.stop()
  }

  private func publish(_ values: [Double]) {
    guard capture != nil, !clients.isEmpty, NSApp.isActive else { return }
    levels = values
    decayTask?.cancel()
    decayTask = Task {
      try? await Task.sleep(for: .milliseconds(250))
      if !Task.isCancelled { levels = [] }
    }
  }
}
