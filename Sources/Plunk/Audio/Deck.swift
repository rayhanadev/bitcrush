import AVFoundation
import AppKit
import AudioToolbox
import MediaPlayer
import PlunkKit

/// One full remix signal chain — player → varispeed → time/pitch → (EQ → filter →
/// reverb) + a parallel bitcrush layer → submix. The engine runs two of these (A/B)
/// so it can beatmatch-crossfade between tracks and hand off without a gap.
/// `submix.outputVolume` is this deck's crossfader gain.
@MainActor
final class Deck {
  let player = AVAudioPlayerNode()
  let varispeed = AVAudioUnitVarispeed()
  let timePitch = AVAudioUnitTimePitch()
  // band 0 Low(shelf) · 1 presence dip · 2 air · 3 bitcrush crossover LP · 4 Mid · 5 High
  let eq = AVAudioUnitEQ(numberOfBands: 6)
  let filterNode = AVAudioUnitEQ(numberOfBands: 1)  // DJ filter sweep / bass-swap
  let reverb = AVAudioUnitReverb()
  let crushBand = AVAudioUnitEQ(numberOfBands: 2)
  let crushGate = AVAudioUnitEffect(
    audioComponentDescription: AudioComponentDescription(
      componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_DynamicsProcessor,
      componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
  let crusher = AVAudioUnitDistortion()
  let crushGain = AVAudioMixerNode()
  let submix = AVAudioMixerNode()

  // per-track state
  private(set) var file: AVAudioFile?
  private(set) var totalFrames: AVAudioFramePosition = 0
  private(set) var sampleRate: Double = 48000
  var seekFrame: AVAudioFramePosition = 0
  private(set) var scheduleGen = 0
  private(set) var duration: Double = 0
  var beat: Tempo.Beat?
  var title = ""
  var artist = ""
  var artwork: MPMediaItemArtwork?
  var peaks: [Float] = []
  /// Fired when this deck's player reaches the end (passes its schedule generation).
  var onFinished: ((Int) -> Void)?

  init() { configureBands() }

  func attach(to engine: AVAudioEngine) {
    for n: AVAudioNode in [
      player, varispeed, timePitch, eq, filterNode, reverb,
      crushBand, crushGate, crusher, crushGain, submix,
    ] { engine.attach(n) }
  }

  // MARK: node configuration

  private func configureBands() {
    let hp = crushBand.bands[0]
    hp.filterType = .highPass
    hp.frequency = 3000
    hp.bypass = false
    let lp = crushBand.bands[1]
    lp.filterType = .lowPass
    lp.frequency = 11000
    lp.bypass = false

    let au = crushGate.audioUnit
    AudioUnitSetParameter(au, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, 0, 0)
    AudioUnitSetParameter(au, kDynamicsProcessorParam_ExpansionThreshold, kAudioUnitScope_Global, 0, -50, 0)
    AudioUnitSetParameter(au, kDynamicsProcessorParam_ExpansionRatio, kAudioUnitScope_Global, 0, 2, 0)
    AudioUnitSetParameter(au, kDynamicsProcessorParam_AttackTime, kAudioUnitScope_Global, 0, 0.003, 0)
    AudioUnitSetParameter(au, kDynamicsProcessorParam_ReleaseTime, kAudioUnitScope_Global, 0, 0.2, 0)

    crusher.loadFactoryPreset(.multiDecimated2)
    crusher.wetDryMix = 100
    crusher.bypass = true
    crushGain.outputVolume = 0

    let bass = eq.bands[0]
    bass.filterType = .lowShelf
    bass.frequency = 110
    bass.bandwidth = 0.6
    bass.bypass = true

    let presence = eq.bands[1]
    presence.filterType = .parametric
    presence.frequency = 3400
    presence.bandwidth = 1.0
    presence.bypass = true

    let air = eq.bands[2]
    air.filterType = .highShelf
    air.frequency = 11000
    air.gain = 2
    air.bypass = true

    let crossover = eq.bands[3]
    crossover.filterType = .lowPass
    crossover.frequency = 3000
    crossover.bypass = true

    let midBand = eq.bands[4]
    midBand.filterType = .parametric
    midBand.frequency = 1200
    midBand.bandwidth = 1.0
    midBand.bypass = true

    let highBand = eq.bands[5]
    highBand.filterType = .highShelf
    highBand.frequency = 8000
    highBand.bypass = true

    let sweep = filterNode.bands[0]
    sweep.filterType = .lowPass
    sweep.frequency = 20000
    sweep.bypass = true
  }

  /// (Re)wire the internal chain for `format` and route the deck into `master`.
  func connect(in engine: AVAudioEngine, to master: AVAudioNode, format: AVAudioFormat) {
    engine.connect(player, to: varispeed, format: format)
    engine.connect(varispeed, to: timePitch, format: format)
    engine.connect(
      timePitch,
      to: [
        AVAudioConnectionPoint(node: eq, bus: 0), AVAudioConnectionPoint(node: crushBand, bus: 0),
      ], fromBus: 0, format: format)
    engine.connect(eq, to: filterNode, format: format)
    engine.connect(filterNode, to: reverb, format: format)
    engine.connect(reverb, to: submix, format: format)
    engine.connect(crushBand, to: crushGate, format: format)
    engine.connect(crushGate, to: crusher, format: format)
    engine.connect(crusher, to: crushGain, format: format)
    engine.connect(crushGain, to: submix, format: format)
    engine.connect(submix, to: master, format: format)
  }

  // MARK: load + params

  /// Load a track's audio + metadata and wire the chain. Returns false if undecodable.
  @discardableResult
  func load(_ track: TrackInfo, in engine: AVAudioEngine, master: AVAudioNode) -> Bool {
    guard let f = try? AVAudioFile(forReading: URL(fileURLWithPath: track.playablePath)) else {
      return false
    }
    file = f
    let format = f.processingFormat
    sampleRate = format.sampleRate
    totalFrames = f.length
    seekFrame = 0
    duration = sampleRate > 0 ? Double(totalFrames) / sampleRate : track.meta.duration
    beat = track.beat
    title = track.meta.title
    artist = track.meta.artist
    artwork = Self.loadArtwork(track.artPath)
    peaks = []
    // ReplayGain-style makeup per deck (the shared limiter can't differ per deck mid-mix)
    eq.globalGain = Float(max(-24, min(24, track.makeupGainDB())))
    connect(in: engine, to: master, format: format)
    return true
  }

  func apply(_ p: RemixParams) {
    if p.linked, p.pitch == 0 {
      varispeed.rate = Float(min(max(p.tempo, 1.0 / 32), 32))
      timePitch.bypass = true
      timePitch.rate = 1
      timePitch.pitch = 0
    } else {
      varispeed.rate = 1
      timePitch.bypass = false
      timePitch.overlap = 16
      timePitch.rate = Float(min(max(p.tempo, 1.0 / 32), 32))
      let extraCents = Double(p.pitch) * 100
      timePitch.pitch = Float(p.linked ? 1200 * log2(p.tempo) + extraCents : extraCents)
    }

    crusher.bypass = !p.bitcrush
    crushGain.outputVolume = p.bitcrush ? 1.3 : 0
    eq.bands[3].bypass = !p.bitcrush

    eq.bands[0].gain = Float(p.bass)
    eq.bands[0].bypass = p.bass == 0
    eq.bands[4].gain = Float(p.mid)
    eq.bands[4].bypass = p.mid == 0
    eq.bands[5].gain = Float(p.high)
    eq.bands[5].bypass = p.high == 0

    let spedUp = p.tempo > 1
    eq.bands[1].gain = Float(-1.5 * min(max((p.tempo - 1) / 0.25, 0), 1.5))
    eq.bands[1].bypass = !spedUp
    eq.bands[2].bypass = !spedUp

    applyFilter(p.filter)
    reverb.wetDryMix = Float(min(max(p.reverb, 0), 1) * 45)
  }

  func applyFilter(_ f: Double) {
    let band = filterNode.bands[0]
    guard abs(f) >= 0.02 else {
      band.bypass = true
      return
    }
    band.bypass = false
    if f < 0 {
      band.filterType = .lowPass
      band.frequency = Float(20000 * pow(250.0 / 20000.0, -f))
    } else {
      band.filterType = .highPass
      band.frequency = Float(20 * pow(2000.0 / 20.0, f))
    }
  }

  /// Force the filter node to a plain high-pass at `hz` — used to sweep the bass-swap
  /// during an automix transition (overrides the user filter until the deck goes live).
  func setBassSwapHighpass(_ hz: Float) {
    let band = filterNode.bands[0]
    band.bypass = false
    band.filterType = .highPass
    band.frequency = max(20, min(1000, hz))
  }

  // MARK: transport

  func startPlayback(fromFrame frame: AVAudioFramePosition? = nil, at when: AVAudioTime? = nil) {
    guard let file else { return }
    if let frame { seekFrame = frame }
    if seekFrame >= totalFrames { seekFrame = 0 }
    let remaining = totalFrames - seekFrame
    guard remaining > 0 else { return }
    scheduleGen += 1
    let gen = scheduleGen
    player.stop()
    player.scheduleSegment(
      file, startingFrame: seekFrame, frameCount: AVAudioFrameCount(remaining), at: when,
      completionCallbackType: .dataPlayedBack
    ) { [weak self] _ in
      Task { @MainActor in self?.onFinished?(gen) }
    }
    player.play()
  }

  /// Stop the player; bump the generation so its completion handler is ignored.
  func stopPlayer() {
    scheduleGen += 1
    player.stop()
  }

  /// Capture the current position into `seekFrame` and stop (for pause).
  func pauseAndStash() {
    seekFrame = currentFrame()
    stopPlayer()
  }

  func currentFrame() -> AVAudioFramePosition {
    guard let nodeTime = player.lastRenderTime,
      let playerTime = player.playerTime(forNodeTime: nodeTime)
    else { return seekFrame }
    return min(totalFrames, seekFrame + playerTime.sampleTime)
  }

  /// The deck's net source-consumption rate (varispeed or time-stretch path).
  var effectiveRate: Double { timePitch.bypass ? Double(varispeed.rate) : Double(timePitch.rate) }

  /// Crossfader gain (0…1).
  var fade: Float {
    get { submix.outputVolume }
    set { submix.outputVolume = newValue }
  }

  var progressFraction: Double {
    totalFrames > 0 ? min(1, Double(currentFrame()) / Double(totalFrames)) : 0
  }

  /// Source-time (seconds) of the next beat at or after the current playhead.
  func nextBeatRealDelay() -> Double? {
    guard let beat, beat.period > 0, effectiveRate > 0 else { return nil }
    let srcNow = Double(currentFrame()) / sampleRate
    var target = beat.nextBeat(after: srcNow)
    if target - srcNow < 0.06 { target += beat.period }  // don't cut it too fine
    return (target - srcNow) / effectiveRate
  }

  private static func loadArtwork(_ path: String?) -> MPMediaItemArtwork? {
    guard let path, let image = NSImage(contentsOfFile: path) else { return nil }
    return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
  }
}
