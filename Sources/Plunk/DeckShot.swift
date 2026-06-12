#if DEBUG
import AVFoundation
import AppKit
import PlunkKit
import SwiftUI

/// Offline deck renderer: with `BITCRUSH_SHOT=1` set, render each deck skin to a PNG
/// in /tmp and exit — the only way to eyeball the menu-bar UI (the live `.window`
/// popover can't be captured). Debug builds only; never ships.
@MainActor
enum DeckShot {
  static func run() {
    let model = AppModel()
    // a rising/swelling RMS silhouette so the waveform reads as real audio
    let peaks: [Float] = (0..<200).map { i in
      let t = Double(i) / 200
      return Float(abs(sin(t * .pi * 7)) * (0.30 + 0.65 * t))
    }
    model.engine._seedPreview(peaks: peaks, duration: 168, progress: 0.38, tempo: 1.25)
    model.applyPreset(.nightcore)
    // dial in some EQ/filter so the knobs render at varied positions
    model.params.bass = 3
    model.params.mid = -2
    model.params.high = 4
    model.params.filter = -0.4
    model.params.bitcrush = true  // show the lit crush state without dropping the preset

    let meta = TrackMeta(
      key: "preview", title: "lovefield", artist: "underscores", duration: 168,
      thumbnail: nil, webpageURL: "", source: "youtube")

    let deck = VStack(spacing: 14) {
      MixingBanner(engine: model.engine)
      DJDeck(meta: meta, baseBPM: 120, vibe: model.currentVibe, engine: model.engine)
    }
    let content =
      deck
      .environmentObject(model)
      .frame(width: 308)
      .padding(16)
      .background(Color(nsColor: .windowBackgroundColor))
    let renderer = ImageRenderer(content: content)
    renderer.scale = 2
    if let img = renderer.nsImage, let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
    {
      try? png.write(to: URL(fileURLWithPath: "/tmp/deck-dj.png"))
    }
    exit(0)
  }

  /// Print detected BPM/phase for cached tracks so beat detection can be sanity-checked
  /// against real audio (`BITCRUSH_BPM=1 swift run Plunk`).
  static func probeBPM() {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    let tracks = base?.appendingPathComponent("plunk/tracks", isDirectory: true)
    let files =
      (try? FileManager.default.contentsOfDirectory(atPath: tracks?.path ?? ""))?
      .filter { $0.hasSuffix(".m4a") }.sorted().prefix(12) ?? []
    for name in files {
      let path = tracks!.appendingPathComponent(name).path
      if let b = BeatAnalyzer.analyze(path: path) {
        print(String(format: "%@  %.1f BPM  phase %.3fs", name, b.bpm, b.phase))
      } else {
        print("\(name)  (no beat)")
      }
    }
    exit(0)
  }

  /// Smoke-test the dual-deck beatmatched transition end-to-end (graph + state machine):
  /// load A, play, force a short transition into B, verify the handoff completes without
  /// crashing and B becomes the active deck. Can't verify how it *sounds*.
  static func probeAutomix() {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    let dir = base!.appendingPathComponent("plunk/tracks", isDirectory: true)
    let m4as =
      ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
      .filter { $0.hasSuffix(".m4a") }.sorted()

    func makeTrack(_ name: String) -> TrackInfo? {
      let path = dir.appendingPathComponent(name).path
      guard let beat = BeatAnalyzer.analyze(path: path),
        let f = try? AVAudioFile(forReading: URL(fileURLWithPath: path))
      else { return nil }
      let meta = TrackMeta(
        key: name, title: name, artist: "probe", duration: Double(f.length) / f.processingFormat.sampleRate,
        thumbnail: nil, webpageURL: "", source: "youtube")
      return TrackInfo(
        meta: meta, originalPath: path, playablePath: path, artPath: nil,
        sampleRate: f.processingFormat.sampleRate, loudnessI: -14, beat: beat)
    }

    let tracks = m4as.compactMap(makeTrack)
    guard tracks.count >= 2 else {
      print("automix probe: need 2 beat-detectable tracks, found \(tracks.count)")
      exit(0)
    }
    let a = tracks[0]
    let b = tracks[1]
    print("A: \(a.meta.key) \(a.beat!.bpm) BPM | B: \(b.meta.key) \(b.beat!.bpm) BPM")

    let engine = EnginePlayer()
    engine.load(a)
    engine.apply(Preset.nightcore.params!)
    engine.play()
    RunLoop.current.run(until: Date().addingTimeInterval(1.0))
    engine._forceAutomix(into: b, params: Preset.nightcore.params!)
    print("transition started; mixing=\(engine._isMixing)")
    // pump the runloop past a 2-bar blend (~3–4 s) plus margin
    RunLoop.current.run(until: Date().addingTimeInterval(8.0))
    print("after blend: mixing=\(engine._isMixing) active=\(engine._currentTitle)")
    print(engine._currentTitle == b.meta.key && !engine._isMixing ? "AUTOMIX PROBE: PASS" : "AUTOMIX PROBE: CHECK")
    exit(0)
  }

  /// Exercise the real DiscordPresence code path (BITCRUSH_DISCORD=1 swift run Plunk).
  static func probeDiscord() {
    let presence = DiscordPresence()
    print(presence.debugProbe())
    Thread.sleep(forTimeInterval: 1.5)  // keep the socket open so the card shows briefly
    print("→ check Discord (clears when this process exits)")
    exit(0)
  }
}
#endif
