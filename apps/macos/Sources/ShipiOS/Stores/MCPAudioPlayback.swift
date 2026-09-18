import AVFoundation
import Observation

@MainActor @Observable final class MCPAudioPlayback {
  private(set) var duration = 0.0
  private(set) var position = 0.0
  private(set) var playing = false
  private(set) var error: String?
  @ObservationIgnored private var player: AVAudioPlayer?
  @ObservationIgnored private var timer: Timer?

  func load(_ data: Data) {
    stop()
    player = nil; duration = 0; position = 0; error = nil
    do {
      let player = try AVAudioPlayer(data: data)
      guard player.duration.isFinite, player.duration > 0, player.prepareToPlay() else {
        throw AgentFailure(message: "音频无法播放。")
      }
      self.player = player
      duration = player.duration
    } catch { self.error = "无法解码工具返回的音频。" }
  }

  func toggle() {
    guard let player else { return }
    if playing { pause(); return }
    if position >= duration { seek(0) }
    guard player.play() else { error = "音频无法播放。"; return }
    playing = true
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    }
  }
  func seek(_ time: Double) {
    guard time.isFinite else { return }
    position = min(duration, max(0, time))
    player?.currentTime = position
  }
  func pause() {
    player?.pause()
    position = player?.currentTime ?? position
    playing = false; timer?.invalidate(); timer = nil
  }
  func stop() {
    player?.stop()
    playing = false; position = 0; timer?.invalidate(); timer = nil
  }
  private func refresh() {
    guard let player else { return }
    position = player.currentTime
    if !player.isPlaying {
      position = duration; playing = false; timer?.invalidate(); timer = nil
    }
  }
  deinit { timer?.invalidate(); player?.stop() }
}
