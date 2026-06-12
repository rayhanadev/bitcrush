import AVFoundation
import PlunkKit

/// Decodes a playable file and estimates its beat grid (BPM + phase) for the automixer.
/// Builds a kick-band energy-flux onset envelope (a one-pole low-pass emphasizes the
/// kick so 4/4 material locks reliably) and hands it to `Tempo.estimate`. Pure CPU —
/// safe to run off the main actor during a pull.
enum BeatAnalyzer {
  static func analyze(path: String) -> Tempo.Beat? {
    guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
    let format = file.processingFormat
    let sr = format.sampleRate
    let total = file.length
    guard sr > 0, total > 2000 else { return nil }

    let hop = 512
    let fps = sr / Double(hop)

    // skip a short intro, then analyze up to ~90 s of the body
    let start = AVAudioFramePosition(min(Double(total) * 0.1, 8 * sr))
    let available = total - start
    let maxFrames = AVAudioFrameCount(min(Double(available), 90 * sr))
    guard maxFrames > AVAudioFrameCount(hop * 32) else { return nil }
    file.framePosition = start

    let chunkCap: AVAudioFrameCount = 1 << 16
    guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkCap) else { return nil }

    // one-pole low-pass (~150 Hz) to isolate the kick
    let rc = 1.0 / (2 * Double.pi * 150)
    let dt = 1.0 / sr
    let alpha = Float(dt / (rc + dt))
    let channels = Int(format.channelCount)

    var onset: [Float] = []
    onset.reserveCapacity(Int(Double(maxFrames) / Double(hop)) + 1)
    var lp: Float = 0
    var prevEnergy: Float = 0
    var hopSum: Float = 0
    var hopCount = 0
    var read: AVAudioFrameCount = 0

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
        s /= Float(channels)
        lp += alpha * (s - lp)  // kick-band
        hopSum += lp * lp
        hopCount += 1
        if hopCount >= hop {
          let energy = (hopSum / Float(hopCount)).squareRoot()
          onset.append(max(0, energy - prevEnergy))  // positive flux = an attack
          prevEnergy = energy
          hopSum = 0
          hopCount = 0
        }
      }
    }

    return Tempo.estimate(onset: onset, fps: fps)
  }
}
