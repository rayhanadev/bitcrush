import Testing

@testable import PlunkKit

@Suite("tempo")
struct TempoTests {
  /// Build an onset envelope with a pulse every `period` frames, starting at `offset`.
  private func clicks(period: Int, offset: Int, count: Int) -> [Float] {
    var env = [Float](repeating: 0.02, count: count)  // some noise floor
    var i = offset
    while i < count {
      env[i] = 1
      i += period
    }
    return env
  }

  @Test("recovers a 120 BPM pulse train")
  func detect120() {
    // fps = 100, 120 BPM → a beat every 0.5s → every 50 frames
    let env = clicks(period: 50, offset: 7, count: 3000)
    let beat = Tempo.estimate(onset: env, fps: 100)
    #expect(beat != nil)
    #expect(abs((beat?.bpm ?? 0) - 120) < 2)
    #expect(abs((beat?.phase ?? 0) - 0.07) < 0.02)  // offset 7 frames @ 100 fps
  }

  @Test("recovers a 128 BPM pulse train (house)")
  func detect128() {
    // 128 BPM @ 100 fps → 46.875 frames; use 47
    let env = clicks(period: 47, offset: 0, count: 4000)
    let beat = Tempo.estimate(onset: env, fps: 100)
    #expect(beat != nil)
    #expect(abs((beat?.bpm ?? 0) - 128) < 3)
  }

  @Test("folds a too-fast detection into the preferred octave")
  func octaveFold() {
    // pulses every 25 frames @ 100 fps = 240 BPM → should fold to 120
    let env = clicks(period: 25, offset: 0, count: 3000)
    let beat = Tempo.estimate(onset: env, fps: 100)
    #expect(beat != nil)
    #expect((beat?.bpm ?? 0) <= 168)
    #expect((beat?.bpm ?? 0) >= 84)
  }

  @Test("nextBeat lands on the grid")
  func grid() {
    let beat = Tempo.Beat(bpm: 120, phase: 0.1)  // period 0.5
    #expect(abs(beat.nextBeat(after: 0.0) - 0.1) < 1e-9)
    #expect(abs(beat.nextBeat(after: 0.2) - 0.6) < 1e-9)
    #expect(abs(beat.nextBeat(after: 0.6) - 0.6) < 1e-9)
  }

  @Test("rejects too-short input")
  func tooShort() {
    #expect(Tempo.estimate(onset: [0, 1, 0, 1], fps: 100) == nil)
  }
}
