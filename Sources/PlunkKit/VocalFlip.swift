import Foundation

/// Parameters for the vocal gender flip (male → female, Little AlterBoy-style).
///
/// A convincing flip moves pitch and formants *independently*: pitch up a few
/// semitones, formants (the vocal-tract-size cue) up by a smaller ratio. The
/// defaults come from Praat's Change Gender guidance — formant ratio 1.1 subtle,
/// 1.2 dramatic — and land the flip *before* the nightcore resample, which then
/// treats the flipped voice exactly like a real female voice.
///
/// The flip runs as a pre-pass producing a flipped intermediate file, so it is
/// preset-agnostic and the live/export chains stay untouched.
public struct VocalFlipRecipe: Codable, Equatable, Sendable {
  public enum Engine: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Two-pass `rubberband` CLI on the whole mix — the pragmatic baseline.
    case rubberband
    /// demucs vocal stem + Praat `Change Gender` + remix — the max-quality tier.
    case praatStems

    public var id: String { rawValue }

    public var label: String {
      switch self {
      case .rubberband: "rubberband (whole mix)"
      case .praatStems: "demucs + Praat (vocal stem)"
      }
    }
  }

  public var engine: Engine
  /// Net vocal pitch-up in semitones (before any nightcore speedup on top).
  /// The realized shift may be smaller — see `effectivePitchSemitones`.
  public var pitchSemitones: Double
  /// Independent formant scale — 1.15 subtle … 1.30 full "nightcore girl".
  public var formantRatio: Double
  /// Porter Robinson-style sheen: light chorus doubling + a short echo.
  public var polish: Bool
  /// Harmonic exciter on the shifted voice — restores the rasp/edge that big
  /// shifts strip out (grunge vocals read male through their *noise*, and thin
  /// out without it).
  public var grit: Bool
  /// Praat engine only: compress pitch excursions around the new median
  /// (<1 tames belted/screamed peaks that would otherwise fly comically high).
  public var pitchRangeFactor: Double

  public init(
    engine: Engine = .rubberband, pitchSemitones: Double = 8,
    formantRatio: Double = 1.3, polish: Bool = false, grit: Bool = false,
    pitchRangeFactor: Double = 1.0
  ) {
    self.engine = engine
    self.pitchSemitones = pitchSemitones
    self.formantRatio = formantRatio
    self.polish = polish
    self.grit = grit
    self.pitchRangeFactor = pitchRangeFactor
  }

  public static let standard = VocalFlipRecipe()

  /// Ceiling for the shifted vocal's median F0. Keeps a fixed big shift from
  /// launching already-high voices (male rock belting starts near 290 Hz) into
  /// chipmunk absurdity — the shift adapts per track instead.
  public static let pitchCeilingHz = 400.0

  /// Self-describing, filesystem-safe token (e.g. "rb-p8.00-f1.30-grit") —
  /// human-readable on purpose: the A/B experiment lives in filenames.
  public var cacheToken: String {
    let eng =
      switch engine {
      case .rubberband: "rb"
      case .praatStems: "praat"
      }
    var base = String(format: "%@-p%.2f-f%.2f", eng, pitchSemitones, formantRatio)
    if pitchRangeFactor != 1.0 { base += String(format: "-r%.2f", pitchRangeFactor) }
    if grit { base += "-grit" }
    if polish { base += "-polish" }
    return base
  }

  /// The pitch shift actually applied: `pitchSemitones`, shrunk when the
  /// track's detected median F0 would exceed `pitchCeilingHz` after shifting.
  /// nil detection (no analysis yet) applies the full shift.
  public func effectivePitchSemitones(detectedF0: Double?) -> Double {
    guard let f0 = detectedF0, f0 > 0 else { return pitchSemitones }
    let headroom = 12 * log2(Self.pitchCeilingHz / f0)
    return max(0, min(pitchSemitones, headroom))
  }

  /// The two-pass split that fakes independent pitch/formant control out of
  /// rubberband's binary formant flag: pass 1 shifts pitch+formants together to
  /// the formant target (`12·log2(formantRatio)` st); pass 2 shifts pitch the
  /// rest of the way with `-F` locking formants where pass 1 left them.
  public func rubberbandPasses(detectedF0: Double? = nil) -> (pass1: Double, pass2: Double) {
    let pass1 = 12 * log2(formantRatio)
    return (pass1, effectivePitchSemitones(detectedF0: detectedF0) - pass1)
  }

  /// Praat's `Change Gender` wants an absolute new pitch median (Hz): the
  /// detected F0 raised by the effective pitch shift, floored to a plausible
  /// female range; 210 Hz (Praat's own guidance) when detection came up empty.
  public func praatPitchMedian(detectedF0: Double?) -> Double {
    guard let f0 = detectedF0, f0 > 0 else { return 210 }
    return min(max(f0 * pow(2, effectivePitchSemitones(detectedF0: f0) / 12), 165), Self.pitchCeilingHz)
  }
}

/// Cache filename stem for a flipped intermediate — prefixed with the track key
/// so a track's flips can be evicted alongside it.
public func flipCacheKey(trackKey: String, recipe: VocalFlipRecipe) -> String {
  "\(trackKey)-flip-\(recipe.cacheToken)"
}

/// ffmpeg `-af` chain for the optional polish: a gentle stereo chorus (the
/// doubled/wide "digital falsetto" sheen) plus one short, quiet slap echo.
/// Starting point — tuned by ear via the BITCRUSH_FLIP probe.
public func buildFlipPolishFilter() -> String {
  "chorus=0.6:0.9:50|60:0.4|0.32:0.25|0.4:2|1.3,aecho=0.8:0.7:40:0.18"
}

/// ffmpeg `-af` stage for the grit knob: a harmonic exciter scoped to the
/// rasp band (~3.5 kHz up) — re-roughens a voice that big pitch/formant
/// shifts have thinned out. Tuned by ear via the BITCRUSH_FLIP probe.
public func buildFlipGritFilter() -> String {
  "aexciter=amount=2.5:drive=8:blend=0:freq=3500:ceil=12000"
}
