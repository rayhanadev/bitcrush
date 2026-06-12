import CryptoKit
import Foundation

/// Format a Double for an ffmpeg arg without a trailing ".0" (e.g. 3.0 → "3").
private func num(_ value: Double) -> String {
  if value == value.rounded() { return String(Int(value)) }
  return String(format: "%g", value)
}

/// Build the ffmpeg `-af` filtergraph for a set of remix params.
///
/// Chain order: resample → de-ess/presence/air (sped-up only) → tempo → bass →
/// reverb → loudness makeup → brickwall limiter. The de-ess/air and the makeup
/// gain are the nightcore-quality wins (machine-verified): pitch-up shoves
/// sibilance into the harsh 3–5 kHz band, and without makeup the remix is quiet.
///
/// - `linked == true` (nightcore/daycore): a single resample sets the speed, so
///   pitch rises/falls with it; `pitch` is an extra offset on top.
/// - `linked == false` keeps tempo and pitch independent.
/// - `loudnessGainDB`: ReplayGain-style makeup toward target loudness (nil = skip).
public func buildAudioFilter(_ p: RemixParams, sampleRate: Int, loudnessGainDB: Double? = nil)
  -> String
{
  var pre: [String] = []  // before the bitcrush split
  var post: [String] = []  // after it
  let pitchFactor = pow(2.0, Double(p.pitch) / 12.0)

  let rate: Double
  var residTempo: Double
  if p.linked {
    rate = p.tempo * pitchFactor
    residTempo = 1 / pitchFactor
  } else {
    rate = pitchFactor
    residTempo = p.tempo / pitchFactor
  }

  if abs(rate - 1) > 1e-6 {
    let target = Int((Double(sampleRate) * rate).rounded())
    pre.append("asetrate=\(target)")
    // mild Kaiser tuning recovers the top octave without re-admitting alias.
    // Do NOT raise filter_size further — verified to worsen aliasing at the 5:4 ratio.
    pre.append("aresample=\(sampleRate):filter_size=64:cutoff=0.97")
  }

  // tame the sibilance/presence that pitching up pushes into the fatiguing 3–5 kHz
  // region; restore a little air on top. Sped-up (nightcore) only — never daycore/slowed.
  if p.tempo > 1 {
    let dip = -1.5 * min(max((p.tempo - 1) / 0.25, 0), 1.5)
    pre.append("deesser=i=0.10:f=0.45")
    pre.append("equalizer=f=3400:width_type=q:w=1.4:g=\(num(dip))")
    pre.append("equalizer=f=12000:width_type=q:w=0.9:g=2")
  }

  // atempo's hard range is [0.5, 100] — chain below 0.5
  while residTempo < 0.5 {
    pre.append("atempo=0.5")
    residTempo /= 0.5
  }
  if abs(residTempo - 1) > 1e-4 {
    pre.append("atempo=\(String(format: "%.6f", residTempo))")
  }

  // 3-band DJ EQ (boost or cut)
  if p.bass != 0 {
    post.append("bass=g=\(num(p.bass)):f=110:w=0.6")
  }
  if p.mid != 0 {
    post.append("equalizer=f=1200:width_type=q:w=1.0:g=\(num(p.mid))")
  }
  if p.high != 0 {
    post.append("treble=g=\(num(p.high)):f=8000:w=0.5")
  }

  // single-knob filter sweep: <0 low-pass down to 250 Hz, >0 high-pass up to 2 kHz
  if abs(p.filter) >= 0.02 {
    if p.filter < 0 {
      let f = 20000 * pow(250.0 / 20000.0, -p.filter)
      post.append("lowpass=f=\(Int(f.rounded()))")
    } else {
      let f = 20 * pow(2000.0 / 20.0, p.filter)
      post.append("highpass=f=\(Int(f.rounded()))")
    }
  }

  // gate below the slider's 2-decimal step: sub-0.01 reverb would round a
  // decay coefficient to "0.000", which aecho rejects (decay must be > 0)
  if p.reverb >= 0.01 {
    let amount = min(p.reverb, 1)
    func decay(_ x: Double) -> String { String(format: "%.3f", x * amount) }
    // denser, pre-delayed, HF-damped tail for the slowed+reverb space
    post.append(
      "aecho=0.85:0.9:20|45|85|140|200:"
        + "\(decay(0.45))|\(decay(0.36))|\(decay(0.27))|\(decay(0.18))|\(decay(0.10))")
    post.append("lowpass=f=8000")
  }

  // ReplayGain-style makeup toward target loudness — a static gain, so no pumping
  let makeup = loudnessGainDB.map { abs($0) > 0.1 } ?? false
  if let g = loudnessGainDB, makeup {
    post.append("volume=\(num(g))dB")
  }

  // brickwall safety net whenever the level is lifted (makeup / EQ boost / reverb / crush)
  if p.bass > 0 || p.mid > 0 || p.high > 0 || p.reverb > 0 || makeup || p.bitcrush {
    let release = p.reverb > 0 ? 100 : 60
    post.append("alimiter=limit=0.97:level=false:attack=5:release=\(release):asc=1")
  }

  guard p.bitcrush else {
    let all = pre + post
    return all.isEmpty ? "anull" : all.joined(separator: ",")
  }

  // Crush only the high "fringe" (>4 kHz) via a crossover: the body (<4 kHz, where
  // vocals/instruments live) stays perfectly clean, while the highs are *replaced*
  // by a crushed version — not merely added on top, which the clean highs would
  // mask (verified: additive moved the band only +2 dB and was inaudible). A gate
  // keeps the crush off quiet passages (bit-reduction is harshest on low-level
  // signal), bit-reduction (no sample decimation) avoids the aliasing fizz that
  // read as clipping, and a 12 kHz lowpass tames the top.
  let preStr = pre.isEmpty ? "" : pre.joined(separator: ",") + ","
  let postStr = post.isEmpty ? "" : "," + post.joined(separator: ",")
  return preStr
    + "asplit[m][c];"
    + "[m]lowpass=f=3000[ml];"  // clean body only
    + "[c]highpass=f=3000,"  // the fringe…
    + "agate=threshold=0.015:range=0.35:ratio=2:attack=5:release=150,"  // duck only true silence
    + "acrusher=bits=4.5:mode=lin:mix=1,lowpass=f=12000,volume=1.3[cc];"  // …crushed, sat hot
    + "[ml][cc]amix=inputs=2:normalize=0"  // recombined crossover
    + postStr
}

/// Deterministic short cache key for a rendered variant of a track.
public func renderCacheKey(
  trackKey: String, params p: RemixParams, format: ExportFormat
) -> String {
  let parts = [
    trackKey,
    String(format: "%.4f", p.tempo),
    String(p.pitch),
    num(p.bass),
    num(p.mid),
    num(p.high),
    String(format: "%.3f", p.filter),
    String(format: "%.3f", p.reverb),
    p.linked ? "1" : "0",
    p.bitcrush ? "1" : "0",
    format.rawValue,
  ]
  let digest = SHA256.hash(data: Data(parts.joined(separator: "|").utf8))
  return digest.map { String(format: "%02x", $0) }.joined().prefix(20).description
}
