import AVFoundation
import AppKit
import AudioToolbox
import MediaPlayer
import PlunkKit
import SwiftUI

/// Dual-deck remix engine. Two full `Deck` chains (A/B) feed a shared master mixer →
/// peak limiter → output. Normally one deck is active; for the automixer the other
/// deck pre-rolls the next track beatmatched + phase-aligned, an ~8-bar bass-swap
/// crossfade hands over, and the decks swap roles with no gap. Everything stays live.
@MainActor
final class EnginePlayer: ObservableObject {
  @Published private(set) var isPlaying = false
  @Published private(set) var progress: Double = 0
  @Published private(set) var peaks: [Float] = []
  @Published private(set) var ready = false
  @Published private(set) var duration: Double = 0
  /// Net speed of the active deck (drives the remixed scrubber duration).
  @Published private(set) var tempo: Double = 1
  /// True while an automix crossfade is underway (UI can show a "mixing" hint).
  @Published private(set) var mixing = false

  var onNaturalFinish: (() -> Void)?
  var onNext: (() -> Void)?
  var onPrevious: (() -> Void)?
  var onNowPlaying: (() -> Void)?
  var onNowPlayingCleared: (() -> Void)?
  /// Fired after an automix hands off to the incoming track so the app can update its
  /// model state (now-playing track, recents, advance the queue, warm the next).
  var onAutomixHandoff: ((TrackInfo) -> Void)?

  /// Whether automix transitions are allowed (mirrors the Settings toggle).
  var automixEnabled = true

  private let engine = AVAudioEngine()
  private let deckA = Deck()
  private let deckB = Deck()
  private let masterMixer = AVAudioMixerNode()
  private let limiter = AVAudioUnitEffect(
    audioComponentDescription: AudioComponentDescription(
      componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
      componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))

  private var currentIsA = true
  private var current: Deck { currentIsA ? deckA : deckB }
  private var incoming: Deck { currentIsA ? deckB : deckA }

  private var timer: Timer?
  private var peaksToken = 0

  // automix
  private var armed: (track: TrackInfo, params: RemixParams)?
  private var transitionTimer: Timer?
  private var transitionStartedAt = Date()
  private var transitionDuration: Double = 0
  private var transitionParams = RemixParams.identity
  private var transitionTrack: TrackInfo?
  /// Beatmatch by bending the OUTGOING (leaving) deck to the incoming's groove so the
  /// incoming plays at its own correct tempo the whole time (no slow-start, no glide).
  /// Ramps `outgoingStartRate → outgoingLockRate` over the first slice of the blend.
  private var outgoingStartRate: Double = 1
  private var outgoingLockRate: Double?

  init() {
    deckA.attach(to: engine)
    deckB.attach(to: engine)
    engine.attach(masterMixer)
    engine.attach(limiter)

    // master bus runs at a fixed format; the mixer converts each deck's file format
    let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    engine.connect(masterMixer, to: limiter, format: fmt)
    engine.connect(limiter, to: engine.mainMixerNode, format: fmt)

    AudioUnitSetParameter(limiter.audioUnit, kLimiterParam_AttackTime, kAudioUnitScope_Global, 0, 0.001, 0)
    AudioUnitSetParameter(limiter.audioUnit, kLimiterParam_DecayTime, kAudioUnitScope_Global, 0, 0.040, 0)

    deckA.onFinished = { [weak self] gen in self?.deckFinished(isA: true, gen: gen) }
    deckB.onFinished = { [weak self] gen in self?.deckFinished(isA: false, gen: gen) }

    configureRemoteCommands()
  }

  // MARK: load

  func load(_ track: TrackInfo) {
    stop()
    cancelTransition()
    ready = false
    progress = 0
    peaks = []
    guard current.load(track, in: engine, master: masterMixer) else { return }
    current.fade = 1
    duration = current.duration
    ready = true
    refreshNowPlaying()
    loadPeaks(for: current)
  }

  #if DEBUG
  func _seedPreview(peaks: [Float], duration: Double, progress: Double, tempo: Double) {
    self.peaks = peaks
    self.duration = duration
    self.progress = progress
    self.tempo = tempo
    self.ready = true
  }

  /// Force a transition for the automix smoke test (`BITCRUSH_AUTOMIX`).
  func _forceAutomix(into track: TrackInfo, params: RemixParams) {
    armed = (track, params)
    guard let beat = current.beat else { return }
    let master = beat.bpm * current.effectiveRate
    beginTransition(master: master, duration: Automix.transitionSeconds(bars: 2, bpm: master))
  }
  var _isMixing: Bool { mixing }
  var _currentTitle: String { current.title }
  #endif

  // MARK: live parameters

  func apply(_ p: RemixParams) {
    tempo = p.tempo
    current.apply(p)
    refreshNowPlaying()
  }

  // MARK: transport (delegates to the active deck)

  func togglePlay() { isPlaying ? pause() : play() }

  func play() {
    guard ready, current.file != nil else { return }
    do {
      if !engine.isRunning { try engine.start() }
    } catch {
      return
    }
    current.startPlayback()
    isPlaying = true
    startTimer()
    refreshNowPlaying()
  }

  func pause() {
    guard isPlaying else { return }
    cancelTransition()
    current.pauseAndStash()
    isPlaying = false
    stopTimer()
    refreshNowPlaying()
  }

  func stop() {
    cancelTransition()
    deckA.stopPlayer()
    deckB.stopPlayer()
    if engine.isRunning { engine.pause() }
    isPlaying = false
    stopTimer()
    clearNowPlaying()
  }

  func seek(to fraction: Double) {
    cancelTransition()
    let clamped = min(max(fraction, 0), 1)
    current.seekFrame = AVAudioFramePosition(Double(current.totalFrames) * clamped)
    progress = clamped
    if isPlaying { current.startPlayback() }
    refreshNowPlaying()
  }

  // MARK: automix arming

  func armAutomix(_ track: TrackInfo, params: RemixParams) {
    armed = (track, params)  // every track gets at least a crossfade; beatmatch is a bonus
  }

  func disarmAutomix() { armed = nil }

  // MARK: internals

  private func deckFinished(isA: Bool, gen: Int) {
    let deck = isA ? deckA : deckB
    guard isA == currentIsA, gen == deck.scheduleGen, !mixing else { return }
    isPlaying = false
    stopTimer()
    deck.seekFrame = 0
    progress = 0
    refreshNowPlaying()
    onNaturalFinish?()
  }

  private func startTimer() {
    stopTimer()
    let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.tick() }
    }
    RunLoop.main.add(t, forMode: .common)
    timer = t
  }

  private func stopTimer() {
    timer?.invalidate()
    timer = nil
  }

  private func tick() {
    guard current.totalFrames > 0 else { return }
    if !mixing { progress = current.progressFraction }
    checkAutomixTrigger()
  }

  // MARK: automix transition

  private func checkAutomixTrigger() {
    // ALWAYS transition when a track is ready (≥ Apple Music's crossfade); the
    // beatmatch is layered on top in beginTransition when the tempos allow.
    guard automixEnabled, !mixing, isPlaying, armed != nil,
      let beat = current.beat, current.effectiveRate > 0, current.sampleRate > 0
    else { return }
    let master = beat.bpm * current.effectiveRate
    guard master > 0 else { return }
    let blend = Automix.transitionSeconds(bars: 8, bpm: master)
    guard blend > 1 else { return }
    let remainingSrc = Double(current.totalFrames - current.currentFrame()) / current.sampleRate
    let remainingReal = remainingSrc / current.effectiveRate
    if remainingReal <= blend { beginTransition(master: master, duration: blend) }
  }

  private func beginTransition(master: Double, duration: Double) {
    guard let armed else { return }
    self.armed = nil
    let inc = incoming
    guard inc.load(armed.track, in: engine, master: masterMixer) else { return }
    inc.apply(armed.params)  // incoming plays at its OWN target tempo — sounds right immediately

    // Beatmatch by bending the OUTGOING (fading) deck to the incoming's groove, so the
    // track you're moving TO never drags. Lock the outgoing's real BPM to the incoming's
    // target real BPM, when that's a small enough bend (else a plain crossfade).
    outgoingStartRate = current.effectiveRate
    outgoingLockRate = nil
    if let inBeat = inc.beat {
      let inTargetReal = inBeat.bpm * armed.params.tempo  // incoming at its own nightcore
      if Automix.canBeatmatch(incomingBPM: master, targetBPM: inTargetReal) {
        let bend = Automix.matchRate(incomingBPM: master, targetBPM: inTargetReal)
        outgoingLockRate = min(4, max(0.25, current.effectiveRate * bend))
      }
    }
    inc.fade = 0
    inc.setBassSwapHighpass(300)
    loadPeaks(for: inc)

    // phase-align the incoming's first downbeat onto the outgoing's next beat
    let cueFrame = AVAudioFramePosition(max(0, (inc.beat?.phase ?? 0)) * inc.sampleRate)
    var when: AVAudioTime?
    if inc.beat != nil, let delay = current.nextBeatRealDelay(),
      let render = current.player.lastRenderTime
    {
      when = AVAudioTime(hostTime: render.hostTime &+ AVAudioTime.hostTime(forSeconds: delay))
    }
    inc.startPlayback(fromFrame: cueFrame, at: when)

    transitionTrack = armed.track
    transitionParams = armed.params
    transitionDuration = duration
    transitionStartedAt = Date()
    mixing = true
    startTransitionTimer()
  }

  private func startTransitionTimer() {
    transitionTimer?.invalidate()
    let t = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.transitionTick() }
    }
    RunLoop.main.add(t, forMode: .common)
    transitionTimer = t
  }

  private func transitionTick() {
    let elapsed = Date().timeIntervalSince(transitionStartedAt)
    let t = transitionDuration > 0 ? min(1, elapsed / transitionDuration) : 1
    current.fade = Float(cos(t * .pi / 2))  // equal-power out
    incoming.fade = Float(sin(t * .pi / 2))  // equal-power in
    incoming.setBassSwapHighpass(Float(300 * pow(20.0 / 300.0, t)))  // open the lows

    // ease the OUTGOING into the locked tempo over the first ~1.5 bars (≈18% of the
    // blend), then hold — the incoming stays at its own tempo throughout
    if let lock = outgoingLockRate {
      let bt = min(1, t / 0.18)
      let e = bt < 0.5 ? 2 * bt * bt : 1 - pow(-2 * bt + 2, 2) / 2
      current.varispeed.rate = Float(outgoingStartRate + (lock - outgoingStartRate) * e)
    }

    progress = incoming.progressFraction  // scrubber follows the incoming during the blend
    if t >= 1 { finishTransition() }
  }

  private func finishTransition() {
    transitionTimer?.invalidate()
    transitionTimer = nil
    let old = current
    old.stopPlayer()
    old.fade = 1  // reset for its next use

    currentIsA.toggle()  // the incoming deck is now the active deck
    current.fade = 1
    current.applyFilter(transitionParams.filter)  // undo the bass-swap

    duration = current.duration
    tempo = current.effectiveRate  // incoming was always at its own tempo → knob matches
    peaks = current.peaks
    progress = current.progressFraction
    mixing = false
    refreshNowPlaying()

    if let track = transitionTrack { onAutomixHandoff?(track) }
    transitionTrack = nil
  }

  private func cancelTransition() {
    guard mixing else { return }
    transitionTimer?.invalidate()
    transitionTimer = nil
    incoming.stopPlayer()
    incoming.fade = 0
    current.fade = 1
    if outgoingLockRate != nil { current.varispeed.rate = Float(outgoingStartRate) }  // unbend
    outgoingLockRate = nil
    mixing = false
    transitionTrack = nil
  }

  // MARK: peaks

  private func loadPeaks(for deck: Deck) {
    guard let url = deck.file?.url else { return }
    peaksToken += 1
    Task.detached(priority: .utility) { [weak self] in
      let p = Self.computePeaks(url: url, bars: 200)
      await self?.assignPeaks(p, to: deck)
    }
  }

  private func assignPeaks(_ p: [Float], to deck: Deck) {
    deck.peaks = p
    if deck === current { peaks = p }
  }

  // MARK: now playing (Control Center / media keys)

  var effectiveDuration: Double { tempo > 0 ? duration / tempo : duration }

  private func configureRemoteCommands() {
    let center = MPRemoteCommandCenter.shared()
    center.playCommand.addTarget { [weak self] _ in
      Task { @MainActor in self?.play() }
      return .success
    }
    center.pauseCommand.addTarget { [weak self] _ in
      Task { @MainActor in self?.pause() }
      return .success
    }
    center.togglePlayPauseCommand.addTarget { [weak self] _ in
      Task { @MainActor in self?.togglePlay() }
      return .success
    }
    center.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
      let position = event.positionTime
      Task { @MainActor in
        guard let self, self.effectiveDuration > 0 else { return }
        self.seek(to: position / self.effectiveDuration)
      }
      return .success
    }
    center.nextTrackCommand.addTarget { [weak self] _ in
      Task { @MainActor in self?.onNext?() }
      return .success
    }
    center.previousTrackCommand.addTarget { [weak self] _ in
      Task { @MainActor in self?.onPrevious?() }
      return .success
    }
  }

  private func refreshNowPlaying() {
    let center = MPNowPlayingInfoCenter.default()
    guard ready, duration > 0 else {
      center.nowPlayingInfo = nil
      center.playbackState = .stopped
      onNowPlayingCleared?()
      return
    }
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: current.title,
      MPMediaItemPropertyArtist: current.artist,
      MPMediaItemPropertyPlaybackDuration: effectiveDuration,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: progress * effectiveDuration,
      MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
    ]
    if let artwork = current.artwork { info[MPMediaItemPropertyArtwork] = artwork }
    center.nowPlayingInfo = info
    center.playbackState = isPlaying ? .playing : .paused
    onNowPlaying?()
  }

  private func clearNowPlaying() {
    let center = MPNowPlayingInfoCenter.default()
    center.nowPlayingInfo = nil
    center.playbackState = .stopped
    onNowPlayingCleared?()
  }

  /// Downsample a file to per-bucket RMS energy (normalized 0…1) for the waveform.
  nonisolated static func computePeaks(url: URL, bars: Int) -> [Float] {
    guard let file = try? AVAudioFile(forReading: url) else { return [] }
    let format = file.processingFormat
    let total = file.length
    guard total > 0 else { return [] }
    let framesPerBar = max(1, Int(total) / bars)
    let chunk: AVAudioFrameCount = 1 << 16
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return [] }

    var result: [Float] = []
    result.reserveCapacity(bars)
    var sumSquares: Double = 0
    var framesInBar = 0
    var overallMax: Float = 0

    func flush() {
      guard framesInBar > 0 else { return }
      let rms = Float((sumSquares / Double(framesInBar)).squareRoot())
      result.append(rms)
      if rms > overallMax { overallMax = rms }
      sumSquares = 0
      framesInBar = 0
    }

    while result.count < bars {
      do { try file.read(into: buffer, frameCount: chunk) } catch { break }
      let n = Int(buffer.frameLength)
      if n == 0 { break }
      guard let channel = buffer.floatChannelData?[0] else { break }
      for i in 0..<n {
        let v = channel[i]
        sumSquares += Double(v) * Double(v)
        framesInBar += 1
        if framesInBar >= framesPerBar {
          flush()
          if result.count >= bars { break }
        }
      }
    }
    if result.count < bars { flush() }

    guard overallMax > 0 else { return result }
    return result.map { $0 / overallMax }
  }
}
