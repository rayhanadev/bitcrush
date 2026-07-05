import Foundation
import Testing

@testable import PlunkKit

@Suite("voice")
struct VoiceTests {
  private let sr = 12000.0  // the analyzer's ×4-decimated rate

  /// A frame of summed sinusoids: (frequency, amplitude) pairs.
  private func tone(_ partials: [(hz: Double, amp: Double)], count: Int = 2048) -> [Float] {
    (0..<count).map { i in
      let t = Double(i) / sr
      return Float(partials.reduce(0) { $0 + $1.amp * sin(2 * .pi * $1.hz * t) })
    }
  }

  @Test("pins a 110 Hz sine (male range)")
  func sine110() {
    let f0 = Voice.yinF0(frame: tone([(110, 0.8)]), sampleRate: sr)
    #expect(f0 != nil)
    #expect(abs((f0 ?? 0) - 110) < 2)
  }

  @Test("pins a 220 Hz sine (female range)")
  func sine220() {
    let f0 = Voice.yinF0(frame: tone([(220, 0.8)]), sampleRate: sr)
    #expect(f0 != nil)
    #expect(abs((f0 ?? 0) - 220) < 2)
  }

  @Test("pins the fundamental of a harmonic stack — no octave error")
  func harmonicStack() {
    // a voice-like spectrum: strong fundamental + decaying harmonics
    let frame = tone([(130, 0.8), (260, 0.5), (390, 0.3)])
    let f0 = Voice.yinF0(frame: frame, sampleRate: sr)
    #expect(f0 != nil)
    #expect(abs((f0 ?? 0) - 130) < 3)
  }

  @Test("silence is unvoiced")
  func silence() {
    #expect(Voice.yinF0(frame: [Float](repeating: 0, count: 2048), sampleRate: sr) == nil)
  }

  @Test("noise is unvoiced")
  func noise() {
    // deterministic LCG noise — aperiodic, so no confident YIN dip
    var seed: UInt64 = 0x2545_F491_4F6C_DD1D
    let frame = (0..<2048).map { _ -> Float in
      seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Float(Int64(bitPattern: seed) >> 40) / Float(1 << 23)
    }
    #expect(Voice.yinF0(frame: frame, sampleRate: sr) == nil)
  }

  @Test("rejects a too-short frame")
  func tooShort() {
    #expect(Voice.yinF0(frame: tone([(110, 0.8)], count: 64), sampleRate: sr) == nil)
  }

  @Test("classifies by median F0 with an ambiguous gray zone")
  func classify() {
    func analysis(_ hz: Double) -> Voice.Analysis {
      Voice.classify(f0s: [Double](repeating: hz, count: 300), totalFrames: 500)
    }
    #expect(analysis(150).gender == .male)
    #expect(analysis(250).gender == .female)
    // 200–230 Hz: male belting overlaps female pop — never flip on a coin toss
    #expect(analysis(215).gender == .ambiguous)
    #expect(abs((analysis(150).medianF0 ?? 0) - 150) < 1e-9)
    #expect(abs(analysis(150).voicedFraction - 0.6) < 1e-9)
  }

  @Test("too few voiced frames reads as instrumental")
  func instrumental() {
    let sparse = Voice.classify(f0s: [Double](repeating: 120, count: 5), totalFrames: 500)
    #expect(sparse.gender == .instrumental)
    let empty = Voice.classify(f0s: [], totalFrames: 500)
    #expect(empty.gender == .instrumental)
    #expect(empty.medianF0 == nil)
    #expect(empty.voicedFraction == 0)
  }

  @Test("a bassline read (sub-95 Hz) is not a very deep male singer")
  func bassRejection() {
    let bass = Voice.classify(f0s: [Double](repeating: 80, count: 300), totalFrames: 500)
    #expect(bass.gender == .instrumental)
    #expect(bass.medianF0 == nil)
    // bass frames also don't dilute a genuine vocal's median
    let mixed = Voice.classify(
      f0s: [Double](repeating: 80, count: 200) + [Double](repeating: 130, count: 100),
      totalFrames: 500)
    #expect(mixed.gender == .male)
    #expect(abs((mixed.medianF0 ?? 0) - 130) < 1e-9)
  }
}
