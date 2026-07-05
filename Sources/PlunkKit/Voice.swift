import Accelerate
import Foundation

/// Detected vocal register of a track's lead vocal, from median F0.
///
/// SUNG registers overlap far more than speech: male rock belting reaches
/// 200–290 Hz (Nirvana choruses sit above much female pop), so median F0 can
/// only separate the confident ends. Below ~200 Hz is reliably male; above
/// ~230 Hz reliably female/already-feminine; the 200–230 Hz middle is
/// `ambiguous` and the flip stays off there (Option-click forces it) — a wrong
/// flip on a female voice is a worse failure than a missed male one.
/// Calibrated empirically against a stem-separated sweep of real tracks.
public enum VocalGender: String, Codable, Equatable, Sendable {
  case male, female, ambiguous, instrumental
}

/// Vocal F0 estimation + gender classification. Pure math (no audio decoding) so
/// it's unit-testable; the app feeds it band-passed mid-channel frames.
public enum Voice {
  /// Per-track vocal statistics, measured once at pull time (like `Tempo.Beat`).
  public struct Analysis: Codable, Equatable, Sendable {
    public var gender: VocalGender
    /// Median F0 over confident voiced frames, in Hz. nil when none were found.
    public var medianF0: Double?
    /// Confident voiced frames / total analyzed frames, 0…1.
    public var voicedFraction: Double

    public init(gender: VocalGender, medianF0: Double?, voicedFraction: Double) {
      self.gender = gender
      self.medianF0 = medianF0
      self.voicedFraction = voicedFraction
    }
  }

  // classification thresholds — the single tuning point for the flip gate.
  // vocalLow/High bound plausible *sung lead-vocal* F0s: medians below ~95 Hz
  // are basslines the tracker locked onto, not voices (male vocal medians in
  // real songs sit ≥ ~100 Hz), so those frames don't count as vocal evidence.
  // maleBelow/femaleAbove are singing-calibrated (see `VocalGender` docs) —
  // speech thresholds (165/180) misread belted male choruses as female.
  static let vocalLow = 95.0
  static let vocalHigh = 340.0
  static let maleBelow = 200.0
  static let femaleAbove = 230.0
  static let voicedFloor = 0.1

  /// YIN F0 estimate for one mono frame: difference function → cumulative-mean
  /// normalization → first dip under `threshold`, refined by parabolic
  /// interpolation. Returns nil for unvoiced/low-confidence frames — the nil is
  /// the confidence gate, so callers can use the voiced count as a vocal detector.
  public static func yinF0(
    frame: [Float], sampleRate: Double,
    minHz: Double = 70, maxHz: Double = 400, threshold: Float = 0.22
  ) -> Double? {
    guard sampleRate > 0, minHz > 0, maxHz > minHz else { return nil }
    let maxLag = Int(sampleRate / minHz)  // lowest F0 → longest lag
    let minLag = max(2, Int(sampleRate / maxHz))
    guard maxLag > minLag, frame.count >= maxLag * 2 else { return nil }

    // difference function d(τ) over a fixed integration window — vDSP keeps
    // this usable in debug builds (the probe sweeps dozens of tracks)
    let window = frame.count - maxLag
    var d = [Float](repeating: 0, count: maxLag + 1)
    var diff = [Float](repeating: 0, count: window)
    frame.withUnsafeBufferPointer { x in
      guard let base = x.baseAddress else { return }
      diff.withUnsafeMutableBufferPointer { scratch in
        guard let s = scratch.baseAddress else { return }
        for lag in 1...maxLag {
          vDSP_vsub(base + lag, 1, base, 1, s, 1, vDSP_Length(window))
          var sum: Float = 0
          vDSP_svesq(s, 1, &sum, vDSP_Length(window))
          d[lag] = sum
        }
      }
    }

    // cumulative-mean-normalized difference d'(τ) — self-normalizing, so the
    // threshold means the same thing regardless of signal level
    var dn = [Float](repeating: 1, count: maxLag + 1)
    var running: Float = 0
    for lag in 1...maxLag {
      running += d[lag]
      dn[lag] = running > 0 ? d[lag] * Float(lag) / running : 1
    }

    // first dip under the threshold, walked down to its local minimum
    var tau = 0
    var lag = minLag
    while lag <= maxLag {
      if dn[lag] < threshold {
        while lag + 1 <= maxLag, dn[lag + 1] < dn[lag] { lag += 1 }
        tau = lag
        break
      }
      lag += 1
    }
    guard tau != 0 else { return nil }  // no confident periodicity — unvoiced

    // parabolic interpolation around the minimum for sub-sample lag precision
    var refined = Double(tau)
    if tau > 1, tau < maxLag {
      let a = Double(dn[tau - 1]), b = Double(dn[tau]), c = Double(dn[tau + 1])
      let denom = a + c - 2 * b
      if abs(denom) > 1e-12 { refined += (a - c) / (2 * denom) }
    }

    let f0 = sampleRate / refined
    return (minHz...maxHz).contains(f0) ? f0 : nil
  }

  /// Classify a track from its voiced-frame F0s. `totalFrames` includes unvoiced
  /// frames. Only frames in the plausible sung-vocal band count as vocal
  /// evidence — a track whose voiced frames are all bassline reads is
  /// `instrumental`, not a very deep male singer.
  public static func classify(f0s: [Double], totalFrames: Int) -> Analysis {
    let vocal = f0s.filter { (vocalLow...vocalHigh).contains($0) }
    guard totalFrames > 0, !vocal.isEmpty else {
      return Analysis(gender: .instrumental, medianF0: nil, voicedFraction: 0)
    }
    let voiced = Double(vocal.count) / Double(totalFrames)
    let median = vocal.sorted()[vocal.count / 2]
    guard voiced >= voicedFloor else {
      return Analysis(gender: .instrumental, medianF0: median, voicedFraction: voiced)
    }
    let gender: VocalGender =
      median < maleBelow ? .male : median > femaleAbove ? .female : .ambiguous
    return Analysis(gender: gender, medianF0: median, voicedFraction: voiced)
  }
}
