import Foundation

/// Pure math for the beatmatched automixer (unit-testable; the engine does the audio).
public enum Automix {
  /// Playback-rate multiplier to apply to the incoming deck so its real BPM matches
  /// `targetBPM`, folded to the nearest half/double so the pitch stays musical
  /// (a DJ matches to the nearest tempo octave, not a 1.4× chipmunk shift).
  public static func matchRate(incomingBPM: Double, targetBPM: Double) -> Double {
    guard incomingBPM > 0, targetBPM > 0 else { return 1 }
    var r = targetBPM / incomingBPM
    while r > 1.5 { r /= 2 }
    while r < 0.75 { r *= 2 }
    return r
  }

  /// The real (heard) BPM of a track playing at `tempo`× its native speed.
  public static func realBPM(baseBPM: Double, tempo: Double) -> Double {
    baseBPM * tempo
  }

  /// Length of an N-bar transition in seconds at `bpm` (assumes 4/4).
  public static func transitionSeconds(bars: Int, bpm: Double, beatsPerBar: Int = 4) -> Double {
    guard bpm > 0 else { return 0 }
    return Double(bars * beatsPerBar) * 60 / bpm
  }

  /// Whether two tracks are close enough to beatmatch cleanly: their matched rate is
  /// within `tolerance` of 1 (i.e. only a small pitch nudge is needed). Outside this,
  /// the engine falls back to a plain crossfade instead of forcing an ugly stretch.
  public static func canBeatmatch(
    incomingBPM: Double, targetBPM: Double, tolerance: Double = 0.18
  ) -> Bool {
    guard incomingBPM > 0, targetBPM > 0 else { return false }
    let r = matchRate(incomingBPM: incomingBPM, targetBPM: targetBPM)
    return abs(r - 1) <= tolerance
  }
}
