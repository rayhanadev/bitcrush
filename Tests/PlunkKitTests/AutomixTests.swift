import Testing

@testable import PlunkKit

@Suite("automix")
struct AutomixTests {
  @Test("small tempo difference → a gentle nudge near 1×")
  func gentleNudge() {
    #expect(abs(Automix.matchRate(incomingBPM: 128, targetBPM: 130) - 1.0156) < 0.001)
    #expect(Automix.canBeatmatch(incomingBPM: 128, targetBPM: 130))
  }

  @Test("double/half tempo folds into a musical range")
  func octaveFold() {
    #expect(abs(Automix.matchRate(incomingBPM: 70, targetBPM: 140) - 1.0) < 1e-9)  // 2× → 1×
    #expect(abs(Automix.matchRate(incomingBPM: 170, targetBPM: 85) - 1.0) < 1e-9)  // 0.5× → 1×
  }

  @Test("wildly different tempos aren't forced into a beatmatch")
  func refuseBadMatch() {
    // 100 → 150 is a 1.5× stretch even after folding — too far
    #expect(!Automix.canBeatmatch(incomingBPM: 100, targetBPM: 150))
  }

  @Test("real BPM scales with the nightcore tempo")
  func realBPM() {
    #expect(abs(Automix.realBPM(baseBPM: 120, tempo: 1.25) - 150) < 1e-9)
  }

  @Test("8 bars at 150 BPM is 12.8 s")
  func length() {
    #expect(abs(Automix.transitionSeconds(bars: 8, bpm: 150) - 12.8) < 1e-9)
  }
}
