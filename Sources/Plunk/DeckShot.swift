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
    model.params.vocalFlip = true  // …and the lit vocal-flip state

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

  /// Print detected vocal register (median F0 + gender) for cached tracks so the
  /// flip gate can be sanity-checked against songs whose vocalists you know
  /// (`BITCRUSH_VOCAL=1 swift run Plunk`). Cross-checks against `aubiopitch`
  /// when installed (`brew install aubio`).
  static func probeVocal() {
    runProbe { await runVocalProbe() }
  }

  /// Run an async probe from the launch callout and exit when it finishes.
  /// MainActor tasks would never run here — we're inside the app-launch
  /// callout, and a nested RunLoop doesn't drain the main dispatch queue — so
  /// the probe body runs detached on the cooperative pool instead.
  private static func runProbe(_ body: @escaping @Sendable () async -> Void) -> Never {
    Task.detached {
      await body()
      exit(0)
    }
    while true { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
  }

  private nonisolated static func runVocalProbe() async {
    let cache = Cache()
    var items: [(name: String, path: String, duration: Double)] = cache.loadRecent().map {
      ("\($0.meta.artist) — \($0.meta.title)".prefix(46).description, $0.playablePath,
       $0.meta.duration)
    }
    if items.isEmpty {
      let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first
      let tracks = base?.appendingPathComponent("plunk/tracks", isDirectory: true)
      items = ((try? FileManager.default.contentsOfDirectory(atPath: tracks?.path ?? "")) ?? [])
        .filter { $0.hasSuffix(".m4a") }.sorted().prefix(12)
        .map { ($0, tracks!.appendingPathComponent($0).path, 0) }
    }
    if let limit = Int(ProcessInfo.processInfo.environment["BITCRUSH_VOCAL_LIMIT"] ?? "") {
      items = Array(items.prefix(limit))
    }
    let aubio = Tools.locate("aubiopitch")
    let mode = FlipTools.demucsPath() != nil ? "demucs vocal stem" : "whole mix (heuristic)"
    print("vocal probe over \(items.count) cached track(s) — mode: \(mode)"
      + (aubio == nil ? " (install aubio for a cross-check column)" : ""))
    for (name, path, duration) in items {
      let began = Date()
      guard let v = await VoiceAnalyzer.detect(path: path, duration: duration) else {
        print("\(name)  (undecodable)")
        continue
      }
      let secs = Date().timeIntervalSince(began)
      var line = String(
        format: "%-48@ %@  %@  voiced %.0f%%",
        name, v.medianF0.map { String(format: "%.1f Hz", $0) } ?? "—",
        v.gender.rawValue, v.voicedFraction * 100)
      if let aubio, let cross = aubioMedianF0(aubio: aubio, path: path) {
        line += String(format: "  · aubio %.1f Hz", cross)
      }
      print(line + String(format: "  (%.1fs)", secs))
    }
  }

  /// Median F0 according to `aubiopitch` (yinfft), for the probe's cross-check
  /// column. Synchronous Process is fine here — debug probe only.
  private nonisolated static func aubioMedianF0(aubio: String, path: String) -> Double? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: aubio)
    proc.arguments = ["-i", path]
    let out = Pipe()
    proc.standardOutput = out
    proc.standardError = FileHandle.nullDevice
    guard (try? proc.run()) != nil else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    // lines of "time hz"; keep plausible vocal fundamentals only
    let f0s = String(decoding: data, as: UTF8.self)
      .split(separator: "\n")
      .compactMap { line -> Double? in
        let cols = line.split(separator: " ")
        guard cols.count >= 2, let hz = Double(cols[1]) else { return nil }
        return (70...400).contains(hz) ? hz : nil
      }
    guard !f0s.isEmpty else { return nil }
    return f0s.sorted()[f0s.count / 2]
  }

  /// Render A/B vocal-flip variants for a few detected-male cached tracks into
  /// /tmp/flip-ab/<key>/ so recipe defaults can be picked by ear
  /// (`BITCRUSH_FLIP=1 swift run Plunk` — probes are DEBUG-only; release builds
  /// strip them). Per variant it writes the raw flip AND the
  /// flip-through-nightcore result (the thing that actually ships), plus an
  /// original-nightcore control and a single-pass "chipmunk" baseline that
  /// shows what the two-pass formant trick is buying.
  /// Overrides: BITCRUSH_FLIP_KEYS=key1,key2 ·
  /// BITCRUSH_FLIP_RECIPES="8:1.25:grit:r0.8,…" · BITCRUSH_FLIP_ENGINES=rubberband
  static func probeFlip() {
    runProbe { await runFlipProbe() }
  }

  private nonisolated static func runFlipProbe() async {
    let env = ProcessInfo.processInfo.environment
    let cache = Cache()
    let flipper = VocalFlipper(cache: cache)
    let engines = FlipTools.availableEngines()
    guard !engines.isEmpty else {
      print("flip probe: no engines available — \(FlipTools.installHint(.rubberband))")
      return
    }

    // pick tracks: explicit keys, else detected-male, else the freshest couple
    var pool = cache.loadRecent()
    guard !pool.isEmpty else {
      print("flip probe: no cached tracks — pull something first")
      return
    }
    if let keys = env["BITCRUSH_FLIP_KEYS"]?.split(separator: ",").map(String.init) {
      pool = pool.filter { keys.contains($0.meta.key) }
      // the adaptive pitch cap needs each track's register — fill missing voice
      for i in pool.indices where pool[i].voice == nil {
        pool[i].voice = await VoiceAnalyzer.detect(
          path: pool[i].playablePath, duration: pool[i].meta.duration)
      }
    } else {
      var males: [TrackInfo] = []
      for var t in pool {
        if t.voice == nil {
          t.voice = await VoiceAnalyzer.detect(path: t.playablePath, duration: t.meta.duration)
        }
        if t.voice?.gender == .male { males.append(t) }
      }
      if males.isEmpty {
        print("flip probe: no detected-male tracks — flipping the 2 most recent anyway")
        pool = Array(pool.prefix(2))
      } else {
        pool = males
      }
    }
    let tracks = pool.prefix(3)

    // recipe specs: "pitch:formant[:polish][:grit][:rN.NN]", e.g. "8:1.25:grit:r0.8"
    let specs = env["BITCRUSH_FLIP_RECIPES"] ?? "6:1.20,7:1.25,8:1.30"
    let parsed = specs.split(separator: ",").compactMap { spec -> VocalFlipRecipe? in
      let parts = spec.split(separator: ":").map(String.init)
      guard parts.count >= 2, let pitch = Double(parts[0]), let formant = Double(parts[1])
      else { return nil }
      var r = VocalFlipRecipe(pitchSemitones: pitch, formantRatio: formant)
      for flag in parts.dropFirst(2) {
        if flag == "polish" { r.polish = true }
        if flag == "grit" { r.grit = true }
        if flag.hasPrefix("r"), let factor = Double(flag.dropFirst()) { r.pitchRangeFactor = factor }
      }
      return r
    }
    guard !parsed.isEmpty else {
      print("flip probe: no valid recipes in BITCRUSH_FLIP_RECIPES")
      return
    }
    // BITCRUSH_FLIP_ENGINES=rubberband narrows the engine set for fast recipe
    // iteration. rubberband gets the full matrix; praatStems does a full-track
    // separation per variant → just the middle recipe unless recipes were
    // given explicitly
    let wanted = env["BITCRUSH_FLIP_ENGINES"].map {
      Set($0.split(separator: ",").map(String.init))
    }
    var variants = engines
      .filter { wanted?.contains($0.rawValue) ?? true }
      .flatMap { engine -> [VocalFlipRecipe] in
        let forEngine =
          engine == .rubberband || env["BITCRUSH_FLIP_RECIPES"] != nil
          ? parsed : [parsed[min(1, parsed.count - 1)]]
        return forEngine.map { recipe in
          var r = recipe
          r.engine = engine
          return r
        }
      }
    // chipmunk baseline: formants slaved 1:1 to pitch (a plain resample-style
    // shift) — if a two-pass variant doesn't beat this, the trick isn't earning
    variants.append(VocalFlipRecipe(pitchSemitones: 4, formantRatio: pow(2, 4.0 / 12)))

    for track in tracks {
      let outDir = URL(fileURLWithPath: "/tmp/flip-ab/\(track.meta.key)", isDirectory: true)
      try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
      let voiceNote = track.voice?.medianF0.map { String(format: " (voice %.0f Hz)", $0) } ?? ""
      print("\n\(track.meta.key) — \(track.meta.title)\(voiceNote)")
      await nightcoreRender(
        track, from: track.playablePath, to: outDir.appendingPathComponent("original-nightcore.m4a"))
      for recipe in variants {
        let began = Date()
        let cached = FileManager.default.fileExists(
          atPath: flipper.cachedURL(for: track, recipe: recipe).path)
        do {
          let flipped = try await flipper.flippedFile(for: track, recipe: recipe)
          let raw = outDir.appendingPathComponent("\(recipe.cacheToken).m4a")
          try? FileManager.default.removeItem(at: raw)
          try? FileManager.default.copyItem(at: flipped, to: raw)
          await nightcoreRender(
            track, from: flipped.path,
            to: outDir.appendingPathComponent("\(recipe.cacheToken)-nightcore.m4a"))
          let secs = Date().timeIntervalSince(began)
          print(String(
            format: "  %@  %.1fs%@", recipe.cacheToken, secs, cached ? " (cached flip)" : ""))
        } catch {
          print("  \(recipe.cacheToken)  FAILED: \(error.localizedDescription)")
        }
      }
    }
    print("\nlisten: open /tmp/flip-ab")
  }

  /// Render `src` through the standard nightcore chain — A/B files should be
  /// judged as the listener hears them, not as raw intermediates.
  private nonisolated static func nightcoreRender(
    _ track: TrackInfo, from src: String, to dest: URL
  ) async {
    let gain = track.loudnessI != nil ? track.makeupGainDB() : nil
    let filter = buildAudioFilter(
      Preset.nightcore.params!, sampleRate: Int(track.sampleRate), loudnessGainDB: gain)
    let result = try? await runCommand(
      "ffmpeg",
      ["-hide_banner", "-nostats", "-y", "-i", src, "-af", filter, "-c:a", "alac", dest.path])
    if result?.code != 0 {
      print("  (nightcore render failed for \(dest.lastPathComponent))")
    }
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
