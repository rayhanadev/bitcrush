import Foundation

/// Remix parameters.
///
/// `linked == true` is the classic nightcore/daycore mode: the track is
/// resampled so pitch follows speed naturally (`pitch` then adds an extra
/// offset on top). `linked == false` gives independent tempo and pitch.
public struct RemixParams: Equatable, Sendable {
  /// Net playback speed, 0.5 – 1.5.
  public var tempo: Double
  /// Semitones, -12 – +12.
  public var pitch: Int
  /// Low-shelf (≈110 Hz) gain in dB — the "Low" EQ knob, -12 … +12.
  public var bass: Double
  /// Mid peaking (≈1.2 kHz) gain in dB — the "Mid" EQ knob, -12 … +12.
  public var mid: Double
  /// High-shelf (≈8 kHz) gain in dB — the "High" EQ knob, -12 … +12.
  public var high: Double
  /// DJ filter sweep, -1 … +1. 0 = off; <0 sweeps a low-pass down; >0 sweeps a
  /// high-pass up. The classic single-knob mixer filter.
  public var filter: Double
  /// Reverb amount, 0 – 1.
  public var reverb: Double
  /// Pitch follows speed (resample) — the authentic nightcore sound.
  public var linked: Bool
  /// Lo-fi bit/sample-rate reduction (bitcrush).
  public var bitcrush: Bool

  public init(
    tempo: Double, pitch: Int, bass: Double, reverb: Double, linked: Bool,
    mid: Double = 0, high: Double = 0, filter: Double = 0, bitcrush: Bool = false
  ) {
    self.tempo = tempo
    self.pitch = pitch
    self.bass = bass
    self.mid = mid
    self.high = high
    self.filter = filter
    self.reverb = reverb
    self.linked = linked
    self.bitcrush = bitcrush
  }

  public static let identity = RemixParams(tempo: 1, pitch: 0, bass: 0, reverb: 0, linked: true)

  /// True when the only change is a linked speed shift — previewable with a
  /// plain resample (no EQ/reverb/independent-pitch processing needed).
  public var isPlainSpeed: Bool {
    pitch == 0 && bass == 0 && mid == 0 && high == 0 && filter == 0 && reverb == 0
  }
}

/// A named remix preset shown as a tab.
public enum Preset: String, CaseIterable, Identifiable, Sendable {
  case nightcore, daycore, slowed, custom

  public var id: String { rawValue }

  public var label: String {
    switch self {
    case .nightcore: "nightcore"
    case .daycore: "daycore"
    case .slowed: "slowed + reverb"
    case .custom: "custom"
    }
  }

  /// Compact label for narrow controls (e.g. the segmented preset picker).
  public var shortLabel: String {
    switch self {
    case .nightcore: "Nightcore"
    case .daycore: "Daycore"
    case .slowed: "Slowed"
    case .custom: "Custom"
    }
  }

  /// The parameters this preset applies, or `nil` for `.custom` (free editing).
  public var params: RemixParams? {
    switch self {
    case .nightcore: RemixParams(tempo: 1.25, pitch: 0, bass: 0, reverb: 0, linked: true)
    case .daycore: RemixParams(tempo: 0.85, pitch: 0, bass: 0, reverb: 0, linked: true)
    case .slowed: RemixParams(tempo: 0.8, pitch: 0, bass: 3, reverb: 0.6, linked: true)
    case .custom: nil
    }
  }
}

/// Human label for a parameter combo — used in export filenames.
public func vibeLabel(_ p: RemixParams) -> String {
  let plain = p.pitch == 0 && p.bass == 0
  if p.linked, p.tempo >= 1.05, plain, p.reverb == 0 { return "nightcore" }
  if p.linked, p.tempo <= 0.95, p.reverb > 0 { return "slowed + reverb" }
  if p.linked, p.tempo <= 0.95, plain, p.reverb == 0 { return "daycore" }
  if p == .identity { return "original" }
  return "remix"
}
