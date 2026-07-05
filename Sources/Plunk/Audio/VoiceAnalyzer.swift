import AVFoundation
import PlunkKit

/// Decodes a playable file and estimates whether its lead vocal reads male or
/// female (for the vocal-flip gate). Mixes down to the mid channel — lead vocals
/// are center-panned — band-passes to the vocal fundamental range so bass/kick
/// below and hats/pads above pollute the pitch tracker less, decimates ×4 (YIN
/// only needs the band ≤1 kHz), then classifies on the median YIN F0
/// (`Voice.classify`). Pure CPU — safe to run off the main actor during a pull.
enum VoiceAnalyzer {
  /// Full detection pipeline. When demucs is installed, isolate the vocals from
  /// a ~50 s excerpt of the song's body and pitch-track the clean stem — on a
  /// full mix the tracker locks onto whatever is loudest and periodic (synth
  /// lines, bass), so stem detection is the difference between a reliable gate
  /// and a coin toss. Falls back to whole-mix analysis without demucs.
  static func detect(path: String, duration: Double) async -> Voice.Analysis? {
    guard let demucs = FlipTools.demucsPath() else { return analyze(path: path) }
    let fm = FileManager.default
    let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("plunk-voice-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: scratch) }
    do {
      try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
      // start past the intro, into the first chorus territory
      let start = duration > 90 ? duration * 0.35 : max(0, duration * 0.15)
      let excerpt = scratch.appendingPathComponent("excerpt.wav")
      let cut = try await runCommand(
        "ffmpeg",
        [
          "-hide_banner", "-nostats", "-y", "-ss", String(format: "%.1f", start), "-t", "50",
          "-i", path, "-map", "0:a:0", "-c:a", "pcm_s16le", excerpt.path,
        ])
      guard cut.code == 0 else { return analyze(path: path) }
      let sep = try await runCommandAt(
        demucs, ["-n", "htdemucs", "--two-stems", "vocals", "-o", scratch.path, excerpt.path])
      let stem = scratch.appendingPathComponent("htdemucs/excerpt/vocals.wav")
      guard sep.code == 0, fm.fileExists(atPath: stem.path) else { return analyze(path: path) }
      return analyze(path: stem.path)
    } catch {
      return analyze(path: path)
    }
  }

  /// Whole-mix analysis — cheap, zero dependencies, heuristic.
  static func analyze(path: String) -> Voice.Analysis? {
    guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
    let format = file.processingFormat
    let sr = format.sampleRate
    let total = file.length
    guard sr > 0, total > 2000 else { return nil }

    let decim = 4
    let decimatedRate = sr / Double(decim)
    let frameLen = 2048
    let hop = 1024

    // skip a short intro, then analyze up to ~60 s of the body
    let start = AVAudioFramePosition(min(Double(total) * 0.1, 8 * sr))
    let available = total - start
    let maxFrames = AVAudioFrameCount(min(Double(available), 60 * sr))
    guard maxFrames > AVAudioFrameCount(frameLen * decim * 4) else { return nil }
    file.framePosition = start

    let chunkCap: AVAudioFrameCount = 1 << 16
    guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkCap) else { return nil }

    // cascaded one-pole band-pass ≈95–1000 Hz: two low-pass stages at 1 kHz (also
    // the anti-alias filter for the ×4 decimation), minus three at 95 Hz (a
    // steeper high-pass — bass fundamentals are the pitch tracker's worst enemy)
    func alpha(_ hz: Double) -> Float {
      let rc = 1.0 / (2 * Double.pi * hz)
      let dt = 1.0 / sr
      return Float(dt / (rc + dt))
    }
    let aLP = alpha(1000)
    let aHP = alpha(95)
    var lp1: Float = 0, lp2: Float = 0, hp1: Float = 0, hp2: Float = 0, hp3: Float = 0

    let channels = Int(format.channelCount)
    var mono: [Float] = []
    mono.reserveCapacity(Int(maxFrames) / decim + 1)
    var read: AVAudioFrameCount = 0
    var idx = 0

    while read < maxFrames {
      let want = min(chunkCap, maxFrames - read)
      buf.frameLength = 0
      do { try file.read(into: buf, frameCount: want) } catch { break }
      let n = Int(buf.frameLength)
      if n == 0 { break }
      read += AVAudioFrameCount(n)
      guard let data = buf.floatChannelData else { break }
      for i in 0..<n {
        var s: Float = 0
        for c in 0..<channels { s += data[c][i] }
        s /= Float(channels)  // mid channel
        lp1 += aLP * (s - lp1)
        lp2 += aLP * (lp1 - lp2)
        hp1 += aHP * (lp2 - hp1)
        hp2 += aHP * (hp1 - hp2)
        hp3 += aHP * (hp2 - hp3)
        if idx % decim == 0 { mono.append(lp2 - hp3) }  // band = LP(1k) − LP(95)
        idx += 1
      }
    }

    guard mono.count >= frameLen else { return nil }
    var f0s: [Double] = []
    var totalFrames = 0
    var pos = 0
    while pos + frameLen <= mono.count {
      totalFrames += 1
      if let f0 = Voice.yinF0(frame: Array(mono[pos..<(pos + frameLen)]), sampleRate: decimatedRate) {
        f0s.append(f0)
      }
      pos += hop
    }
    guard totalFrames > 0 else { return nil }
    return Voice.classify(f0s: f0s, totalFrames: totalFrames)
  }
}
