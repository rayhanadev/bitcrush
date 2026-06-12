import Foundation

/// Tempo + beat-phase estimation from an onset-strength envelope. Pure math (no audio
/// decoding) so it's unit-testable; the app feeds it an energy-flux envelope.
///
/// Assumes a roughly constant tempo (true for most produced music), which is what lets
/// the automixer phase-lock two decks: match BPM so the beat periods are equal, align
/// the phase once, and the grids stay in sync for the length of a transition.
public enum Tempo {
  public struct Beat: Sendable, Equatable, Codable {
    /// Beats per minute.
    public var bpm: Double
    /// Offset of the first beat from t=0, in seconds (0 ..< one beat period).
    public var phase: Double
    public init(bpm: Double, phase: Double) {
      self.bpm = bpm
      self.phase = phase
    }
    /// Seconds per beat.
    public var period: Double { bpm > 0 ? 60 / bpm : 0 }
    /// The beat-grid time at or after `t`.
    public func nextBeat(after t: Double) -> Double {
      guard period > 0 else { return t }
      let n = ((t - phase) / period).rounded(.up)
      return phase + max(0, n) * period
    }
  }

  /// Estimate tempo from an onset envelope sampled at `fps` frames/sec.
  /// `range` folds the result into a preferred BPM octave.
  public static func estimate(
    onset: [Float], fps: Double, range: ClosedRange<Double> = 84...168
  ) -> Beat? {
    guard onset.count > 32, fps > 0, range.lowerBound > 0 else { return nil }

    // high-pass the envelope (subtract mean, half-wave rectify) to emphasize attacks
    let mean = onset.reduce(0, +) / Float(onset.count)
    let x = onset.map { max(0, $0 - mean) }

    let minLag = max(1, Int((60.0 / range.upperBound) * fps))  // fastest BPM → shortest lag
    let maxLag = Int((60.0 / range.lowerBound) * fps)
    guard maxLag > minLag, maxLag < x.count else { return nil }

    func autocorr(_ lag: Int) -> Float {
      guard lag > 0, lag < x.count else { return 0 }
      var s: Float = 0
      var i = 0
      while i + lag < x.count {
        s += x[i] * x[i + lag]
        i += 1
      }
      return s / Float(x.count - lag)
    }

    var bestLag = minLag
    var bestScore: Float = -1
    for lag in minLag...maxLag {
      let s = autocorr(lag)
      if s > bestScore {
        bestScore = s
        bestLag = lag
      }
    }
    guard bestScore > 0 else { return nil }

    // octave-fold the period into [minLag, maxLag] (keeps the grid phase-compatible)
    var lag = bestLag
    while Double(lag) * 2 <= Double(maxLag) && autocorr(lag * 2) >= bestScore * 0.5 { lag *= 2 }
    while lag > maxLag { lag /= 2 }
    while lag < minLag { lag *= 2 }

    let bpm = 60.0 * fps / Double(lag)

    // beat phase: the comb offset (0..<lag) that collects the most onset energy
    var bestOffset = 0
    var bestComb: Float = -1
    for offset in 0..<lag {
      var s: Float = 0
      var k = offset
      while k < x.count {
        s += x[k]
        k += lag
      }
      if s > bestComb {
        bestComb = s
        bestOffset = offset
      }
    }

    return Beat(bpm: bpm, phase: Double(bestOffset) / fps)
  }
}
