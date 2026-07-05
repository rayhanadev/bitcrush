import Foundation
import Testing

@testable import PlunkKit

@Suite("vocal flip")
struct VocalFlipTests {
  @Test("two-pass split: pass 1 hits the formant ratio, passes sum to the pitch target")
  func passMath() {
    let r = VocalFlipRecipe(pitchSemitones: 4, formantRatio: 1.15)
    let (pass1, pass2) = r.rubberbandPasses()
    #expect(abs(pass1 - 12 * log2(1.15)) < 1e-9)
    #expect(abs(pass1 + pass2 - 4) < 1e-9)
  }

  @Test("formant ratio 1.0 degenerates to a plain formant-preserved shift")
  func noFormantShift() {
    let (pass1, pass2) = VocalFlipRecipe(pitchSemitones: 3, formantRatio: 1.0).rubberbandPasses()
    #expect(abs(pass1) < 1e-9)
    #expect(abs(pass2 - 3) < 1e-9)
  }

  @Test("pitch shift adapts to the detected register instead of chipmunking")
  func adaptivePitch() {
    let r = VocalFlipRecipe(pitchSemitones: 8, formantRatio: 1.25)
    // low pop tenor (blackbear ~220 Hz): full +8 fits under the 400 Hz ceiling
    #expect(abs(r.effectivePitchSemitones(detectedF0: 220) - 8) < 1e-9)
    // high rock belting (~292 Hz): shrinks to the ceiling's headroom
    let capped = r.effectivePitchSemitones(detectedF0: 292)
    #expect(abs(capped - 12 * log2(400.0 / 292)) < 1e-9)
    #expect(capped < 8)
    // no detection → full shift; absurd detection can't go negative
    #expect(abs(r.effectivePitchSemitones(detectedF0: nil) - 8) < 1e-9)
    #expect(r.effectivePitchSemitones(detectedF0: 500) == 0)
    // the cap flows into the two-pass split (pass 2 absorbs the shrink)
    let (pass1, pass2) = r.rubberbandPasses(detectedF0: 292)
    #expect(abs(pass1 - 12 * log2(1.25)) < 1e-9)
    #expect(abs(pass1 + pass2 - capped) < 1e-9)
  }

  @Test("cache token is deterministic, readable, and varies with every knob")
  func cacheTokens() {
    let base = VocalFlipRecipe.standard
    #expect(base.cacheToken == "rb-p8.00-f1.30")
    #expect(base.cacheToken == VocalFlipRecipe().cacheToken)

    var engine = base
    engine.engine = .praatStems
    var pitch = base
    pitch.pitchSemitones = 5
    var formant = base
    formant.formantRatio = 1.2
    var polish = base
    polish.polish = true
    var grit = base
    grit.grit = true
    var range = base
    range.pitchRangeFactor = 0.8
    let tokens = [base, engine, pitch, formant, polish, grit, range].map(\.cacheToken)
    #expect(Set(tokens).count == tokens.count)
    #expect(polish.cacheToken.hasSuffix("-polish"))
    #expect(grit.cacheToken.hasSuffix("-grit"))
    #expect(range.cacheToken.contains("-r0.80"))

    // filesystem-safe: no separators or characters needing escaping
    for token in tokens {
      #expect(token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." })
    }
  }

  @Test("flip cache key is prefixed by the track key for evict-with-parent")
  func cacheKey() {
    let key = flipCacheKey(trackKey: "youtube-abc123", recipe: .standard)
    #expect(key == "youtube-abc123-flip-rb-p8.00-f1.30")
  }

  @Test("praat pitch median raises the detected F0 and clamps to the ceiling")
  func praatMedian() {
    let r = VocalFlipRecipe(pitchSemitones: 8, formantRatio: 1.25)
    // 220 Hz + 8 st ≈ 349 Hz — inside the range, unclamped
    #expect(abs(r.praatPitchMedian(detectedF0: 220) - 220 * pow(2, 8.0 / 12)) < 1e-9)
    // high belting lands exactly on the shared ceiling via the adaptive cap
    #expect(abs(r.praatPitchMedian(detectedF0: 292) - 400) < 1e-6)
    // nil falls back to Praat's 210 Hz guidance
    #expect(abs(r.praatPitchMedian(detectedF0: nil) - 210) < 1e-9)
  }

  @Test("polish and grit filters use real ffmpeg filter names")
  func treatmentFilters() {
    #expect(buildFlipPolishFilter().contains("chorus="))
    #expect(buildFlipPolishFilter().contains("aecho="))
    #expect(buildFlipGritFilter().contains("aexciter="))
  }
}
