import Testing

@testable import PlunkKit

@Suite("filtergraph")
struct FilterGraphTests {
  @Test("identity with no makeup is a no-op")
  func identity() {
    #expect(buildAudioFilter(.identity, sampleRate: 48000) == "anull")
  }

  @Test("nightcore: resample + de-ess/presence dip/air, no limiter without boost/makeup")
  func nightcore() {
    let af = buildAudioFilter(Preset.nightcore.params!, sampleRate: 48000)
    #expect(af.contains("asetrate=60000"))
    #expect(af.contains("aresample=48000:filter_size=64:cutoff=0.97"))
    #expect(af.contains("deesser="))
    #expect(af.contains("equalizer=f=3400:width_type=q:w=1.4:g=-1.5"))  // presence dip
    #expect(af.contains("equalizer=f=12000"))  // air
    #expect(!af.contains("alimiter"))  // no bass/reverb/makeup here
  }

  @Test("daycore resamples down and is NOT de-essed (only sped-up audio is)")
  func daycore() {
    let af = buildAudioFilter(Preset.daycore.params!, sampleRate: 48000)
    #expect(af.contains("asetrate=40800"))
    #expect(!af.contains("deesser"))
    #expect(!af.contains("equalizer=f=3400"))
  }

  @Test("independent pitch shift preserves tempo via atempo, no de-ess at tempo 1")
  func independentPitch() {
    let p = RemixParams(tempo: 1, pitch: 12, bass: 0, reverb: 0, linked: false)
    let af = buildAudioFilter(p, sampleRate: 48000)
    #expect(af.contains("asetrate=96000"))
    #expect(af.contains("atempo=0.500000"))
    #expect(!af.contains("deesser"))
  }

  @Test("extreme slowdown chains atempo within its [0.5, 100] range")
  func extremeSlow() {
    let p = RemixParams(tempo: 0.3, pitch: 0, bass: 0, reverb: 0, linked: false)
    #expect(buildAudioFilter(p, sampleRate: 48000) == "atempo=0.5,atempo=0.600000")
  }

  @Test("slowed + reverb: speed, bass, dense damped echo tail, tuned limiter")
  func slowedReverb() {
    let af = buildAudioFilter(Preset.slowed.params!, sampleRate: 48000)
    #expect(af.contains("asetrate=38400"))
    #expect(af.contains("bass=g=3:f=110:w=0.6"))
    #expect(af.contains("aecho=0.85:0.9:20|45|85|140|200:"))
    #expect(af.contains("lowpass=f=8000"))
    #expect(af.contains("alimiter=limit=0.97:level=false:attack=5:release=100:asc=1"))
    #expect(!af.contains("deesser"))  // slowed is not sped up
  }

  @Test("sub-threshold reverb is treated as off (no aecho 0.000)")
  func tinyReverbGated() {
    let p = RemixParams(tempo: 1, pitch: 0, bass: 0, reverb: 0.001, linked: true)
    #expect(!buildAudioFilter(p, sampleRate: 48000).contains("aecho"))
  }

  @Test("loudness makeup adds a static volume gain and engages the limiter")
  func makeupGain() {
    let af = buildAudioFilter(.identity, sampleRate: 48000, loudnessGainDB: -8)
    #expect(af.contains("volume=-8dB"))
    #expect(af.contains("alimiter="))  // makeup gain → limiter safety net
  }

  @Test("no makeup filter for a negligible gain")
  func negligibleMakeup() {
    #expect(buildAudioFilter(.identity, sampleRate: 48000, loudnessGainDB: 0.05) == "anull")
  }

  @Test("bass boost engages the tuned limiter")
  func bassBoost() {
    let p = RemixParams(tempo: 1, pitch: 0, bass: 8, reverb: 0, linked: true)
    let af = buildAudioFilter(p, sampleRate: 48000)
    #expect(af.contains("bass=g=8:f=110:w=0.6"))
    #expect(af.contains("alimiter=limit=0.97:level=false:attack=5:release=60:asc=1"))
  }

  @Test("bitcrush splits out the high fringe, crushes only that, mixes back")
  func bitcrush() {
    var p = Preset.nightcore.params!
    let plain = buildAudioFilter(p, sampleRate: 48000)
    p.bitcrush = true
    let crushed = buildAudioFilter(p, sampleRate: 48000)
    #expect(!plain.contains("acrusher"))
    #expect(crushed.contains("asplit[m][c]"))  // crossover split
    #expect(crushed.contains("[m]lowpass=f=3000"))  // clean body
    #expect(crushed.contains("[c]highpass=f=3000"))  // the fringe…
    #expect(crushed.contains("agate="))  // gated so it follows the program
    #expect(crushed.contains("acrusher="))  // …crushed
    #expect(crushed.contains("lowpass=f=12000"))  // top tamed
    #expect(crushed.contains("[ml][cc]amix=inputs=2:normalize=0"))  // recombined
    #expect(crushed.contains("alimiter"))  // safety net engaged
    let keyPlain = renderCacheKey(trackKey: "x", params: Preset.nightcore.params!, format: .mp3)
    let keyCrush = renderCacheKey(trackKey: "x", params: p, format: .mp3)
    #expect(keyPlain != keyCrush)
  }

  @Test("cache key is deterministic and varies with params")
  func cacheKey() {
    let a = renderCacheKey(trackKey: "youtube-abc", params: .nightcore, format: .mp3)
    let b = renderCacheKey(trackKey: "youtube-abc", params: .nightcore, format: .mp3)
    let c = renderCacheKey(trackKey: "youtube-abc", params: .nightcore, format: .flac)
    #expect(a == b)
    #expect(a != c)
    #expect(a.count == 20)
  }

  @Test("cache key varies with the vocal flip")
  func cacheKeyVocalFlip() {
    var p = RemixParams.nightcore
    p.vocalFlip = true
    let keyPlain = renderCacheKey(trackKey: "x", params: Preset.nightcore.params!, format: .mp3)
    let keyFlip = renderCacheKey(trackKey: "x", params: p, format: .mp3)
    #expect(keyPlain != keyFlip)
  }

  @Test("vibe labels match the preset combos")
  func vibes() {
    #expect(vibeLabel(Preset.nightcore.params!) == "nightcore")
    #expect(vibeLabel(Preset.daycore.params!) == "daycore")
    #expect(vibeLabel(Preset.slowed.params!) == "slowed + reverb")
    #expect(vibeLabel(.identity) == "original")
  }

  @Test("vocal flip doesn't change the vibe label — the suffix is a call-site concern")
  func vibeUnchangedByFlip() {
    var p = Preset.nightcore.params!
    p.vocalFlip = true
    #expect(vibeLabel(p) == "nightcore")
  }
}

extension RemixParams {
  fileprivate static var nightcore: RemixParams { Preset.nightcore.params! }
}
