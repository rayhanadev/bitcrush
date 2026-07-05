import PlunkKit
import SwiftUI

/// The read-only "nightcore DJ" surface — a compact horizontal strip: a small spinning
/// disc, the track + live BPM/vibe, transport, a thin scrubbable waveform, and the one
/// control that's actually used — Bitcrush. Knobs/presets live in a collapsed Effects
/// section; this is for *watching* the auto-DJ, not fiddling.
struct DJDeck: View {
  let meta: TrackMeta
  /// Native BPM of the track; multiplied by the live tempo for the heard BPM.
  let baseBPM: Double?
  let vibe: String
  @ObservedObject var engine: EnginePlayer
  @EnvironmentObject var model: AppModel

  private var heardBPM: Int? {
    guard let baseBPM, engine.tempo > 0 else { return nil }
    return Int((baseBPM * engine.tempo).rounded())
  }

  var body: some View {
    VStack(spacing: 10) {
      HStack(spacing: 12) {
        disc(46)
        VStack(alignment: .leading, spacing: 3) {
          Text(meta.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
          metaLine.font(.caption).lineLimit(1).minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Button(action: model.export) {
          Image(systemName: model.exporting ? "hourglass" : "arrow.down.circle")
        }
        .buttonStyle(.plain).foregroundStyle(.secondary).disabled(model.exporting)
        .help("Save the remix")
      }

      HStack(spacing: 12) {
        TransportRow(engine: engine, spacing: 16, compact: true)
        Waveform(peaks: engine.peaks, progress: engine.progress, height: 20, onSeek: engine.seek(to:))
        Text(time).font(.system(size: 10, weight: .medium, design: .monospaced))
          .foregroundStyle(.secondary).fixedSize()
        FlipButton(compact: true)
        BitcrushButton(compact: true)
      }
    }
    .plunkCard()
  }

  // MARK: small spinning disc

  private func disc(_ size: CGFloat) -> some View {
    Spinner(spinning: engine.isPlaying, period: 2.2) {
      ZStack {
        Circle().fill(
          RadialGradient(colors: [Color(white: 0.16), .black], center: .center, startRadius: 1, endRadius: size / 2))
        label.frame(width: size * 0.46, height: size * 0.46).clipShape(Circle())
          .overlay(Circle().strokeBorder(.black.opacity(0.4)))
        Circle().fill(Color(white: 0.85)).frame(width: 4, height: 4)
        Circle().fill(.white.opacity(0.5)).frame(width: 3, height: 3).offset(y: -size * 0.4)
      }
    }
    .frame(width: size, height: size)
  }

  @ViewBuilder private var label: some View {
    if let thumb = meta.thumbnail, let url = URL(string: thumb) {
      AsyncImage(url: url) { $0.resizable().aspectRatio(contentMode: .fill) } placeholder: {
        Circle().fill(.pink.opacity(0.6))
      }
    } else {
      Circle().fill(.pink.opacity(0.7))
        .overlay(Image(systemName: "music.note").font(.caption2).foregroundStyle(.white))
    }
  }

  /// artist (secondary) · BPM · vibe (pink) on one line.
  private var metaLine: Text {
    var t = Text(meta.artist).foregroundColor(.secondary)
    if let heardBPM {
      t = t + Text("  ·  \(heardBPM) BPM").foregroundColor(.pink).monospacedDigit()
    }
    return t + Text("  ·  \(vibe)").foregroundColor(.pink)
  }

  private var time: String {
    let total = engine.effectiveDuration
    return "\(formatDuration(engine.progress * total)) / \(formatDuration(total))"
  }
}
