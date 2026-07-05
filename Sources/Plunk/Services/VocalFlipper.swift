import Foundation
import PlunkKit

/// Locates the optional vocal-flip tools. Deliberately separate from
/// `Tools.missing()` — the flip is feature-gated, never a launch requirement.
enum FlipTools {
  /// Praat installs as a GUI .app (brew cask), so it lives at a fixed path
  /// rather than on PATH; its binary is fully headless with `--run`.
  static let praatBinary = "/Applications/Praat.app/Contents/MacOS/Praat"

  static func rubberbandPath() -> String? { Tools.locate("rubberband") }

  /// demucs installs via pip/pipx, which don't land in Homebrew's dirs.
  static func demucsPath() -> String? {
    if let path = Tools.locate("demucs") { return path }
    let fm = FileManager.default
    var candidates = ["\(NSHomeDirectory())/.local/bin/demucs"]
    let pyBase = "\(NSHomeDirectory())/Library/Python"
    for v in (try? fm.contentsOfDirectory(atPath: pyBase)) ?? [] {
      candidates.append("\(pyBase)/\(v)/bin/demucs")
    }
    return candidates.first { fm.isExecutableFile(atPath: $0) }
  }

  static func praatAvailable() -> Bool {
    FileManager.default.isExecutableFile(atPath: praatBinary)
  }

  static func availableEngines() -> [VocalFlipRecipe.Engine] {
    var engines: [VocalFlipRecipe.Engine] = []
    if rubberbandPath() != nil { engines.append(.rubberband) }
    if praatAvailable(), demucsPath() != nil { engines.append(.praatStems) }
    return engines
  }

  static func installHint(_ engine: VocalFlipRecipe.Engine) -> String {
    switch engine {
    case .rubberband: "install it with `brew install rubberband`"
    case .praatStems: "install with `brew install --cask praat` + `pipx install demucs`"
    }
  }
}

/// Renders (and caches) the flipped intermediate a track plays/exports from when
/// the vocal flip is on. The flip is a pre-pass — pitch up a few semitones with
/// formants moved independently — so the normal remix chain runs on top of the
/// result unchanged, and the nightcore resample treats the flipped voice exactly
/// like a real female voice.
struct VocalFlipper: Sendable {
  let cache: Cache

  /// Cache location for this track + recipe. The *realized* pitch is baked into
  /// the name when the adaptive cap shrinks it, so detection landing after an
  /// early render can't serve a stale uncapped file.
  func cachedURL(for track: TrackInfo, recipe: VocalFlipRecipe) -> URL {
    let effective = recipe.effectivePitchSemitones(detectedF0: track.voice?.medianF0)
    var name = flipCacheKey(trackKey: track.meta.key, recipe: recipe)
    if abs(effective - recipe.pitchSemitones) > 0.005 {
      name += String(format: "-e%.2f", effective)
    }
    return cache.flipsDir.appendingPathComponent("\(name).m4a")
  }

  /// The flipped ALAC intermediate for `track` — cached per track + recipe.
  /// Cancellable: `runCommand` terminates the child when the Task is cancelled.
  func flippedFile(for track: TrackInfo, recipe: VocalFlipRecipe) async throws -> URL {
    let dest = cachedURL(for: track, recipe: recipe)
    if FileManager.default.fileExists(atPath: dest.path) { return dest }
    switch recipe.engine {
    case .rubberband: try await renderRubberband(track, recipe, to: dest)
    case .praatStems: try await renderPraatStems(track, recipe, to: dest)
    }
    return dest
  }

  /// Two-pass rubberband trick on the whole mix (see `rubberbandPasses`):
  /// pass 1 moves pitch+formants together to the formant target, pass 2 moves
  /// pitch the rest of the way with `-F` holding formants in place. R3 (`-3`)
  /// is the engine rubberband documents as best for vocals.
  private func renderRubberband(
    _ track: TrackInfo, _ recipe: VocalFlipRecipe, to dest: URL
  ) async throws {
    guard FlipTools.rubberbandPath() != nil else { throw ProcessError.notFound("rubberband") }
    let id = UUID().uuidString
    let wavIn = cache.rendersDir.appendingPathComponent("flip-\(id)-in.wav")
    let wavMid = cache.rendersDir.appendingPathComponent("flip-\(id)-mid.wav")
    let wavOut = cache.rendersDir.appendingPathComponent("flip-\(id)-out.wav")
    let tmp = cache.rendersDir.appendingPathComponent("flip-\(id).m4a")
    defer {
      for f in [wavIn, wavMid, wavOut, tmp] { try? FileManager.default.removeItem(at: f) }
    }

    // rubberband reads/writes plain wav — decode the lossless playable copy
    try await ffmpegStep(
      ["-i", track.playablePath, "-map", "0:a:0", "-c:a", "pcm_s24le", wavIn.path])

    // skip a pass when its shift is negligible (e.g. formantRatio 1.0) — every
    // R3 pass costs render time and adds a little smear. Pitch adapts to the
    // track's detected register (see effectivePitchSemitones).
    let (pass1, pass2) = recipe.rubberbandPasses(detectedF0: track.voice?.medianF0)
    var current = wavIn
    if abs(pass1) >= 0.01 {
      try await step("rubberband", ["-3", "-p", fmt(pass1), current.path, wavMid.path])
      current = wavMid
    }
    if abs(pass2) >= 0.01 {
      try await step("rubberband", ["-3", "-F", "-p", fmt(pass2), current.path, wavOut.path])
      current = wavOut
    }

    var encodeArgs = ["-i", current.path, "-map", "0:a:0"]
    if let filter = flipEncodeFilter(recipe) { encodeArgs += ["-af", filter] }
    encodeArgs += ["-c:a", "alac", tmp.path]
    try await ffmpegStep(encodeArgs)

    try? FileManager.default.removeItem(at: dest)
    try FileManager.default.moveItem(at: tmp, to: dest)
  }

  /// Max-quality tier: demucs isolates the vocal stem, Praat's `Change gender`
  /// (a true independent formant-ratio + pitch-median resynthesis, purpose-built
  /// for this in speech science) flips only the voice, and the untouched
  /// instrumental is mixed back in. Slow — a full-track separation — but the
  /// instrumental stays pristine.
  private func renderPraatStems(
    _ track: TrackInfo, _ recipe: VocalFlipRecipe, to dest: URL
  ) async throws {
    guard let demucs = FlipTools.demucsPath() else { throw ProcessError.notFound("demucs") }
    guard FlipTools.praatAvailable() else { throw ProcessError.notFound("praat") }
    let fm = FileManager.default
    let scratch = cache.rendersDir.appendingPathComponent(
      "flip-praat-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: scratch) }

    // decode → separate (demucs resamples everything to 44.1 kHz)
    let wavIn = scratch.appendingPathComponent("in.wav")
    try await ffmpegStep(["-i", track.playablePath, "-map", "0:a:0", "-c:a", "pcm_s16le", wavIn.path])
    let sep = try await runCommandAt(
      demucs, ["-n", "htdemucs", "--two-stems", "vocals", "-o", scratch.path, wavIn.path])
    let vocals = scratch.appendingPathComponent("htdemucs/in/vocals.wav")
    let instrumental = scratch.appendingPathComponent("htdemucs/in/no_vocals.wav")
    guard sep.code == 0, fm.fileExists(atPath: vocals.path), fm.fileExists(atPath: instrumental.path)
    else { throw ProcessError.failed(tool: "demucs", stderr: tailError(sep.stderrString)) }

    // Praat wants a mono, predictable input; vocals are center-panned anyway
    let vocalMono = scratch.appendingPathComponent("vocal-mono.wav")
    try await ffmpegStep(["-i", vocals.path, "-ac", "1", vocalMono.path])

    // headless Change gender: pitch floor/ceiling for singing, independent
    // formant ratio, absolute pitch-median target seeded from detection, and a
    // range factor that can tame belted/screamed peaks (<1 compresses)
    let script = scratch.appendingPathComponent("flip.praat")
    try """
    form Flip
      sentence inFile
      sentence outFile
      real formantRatio
      real pitchMedian
      real rangeFactor
    endform
    sound = Read from file: inFile$
    flipped = Change gender: 75, 600, formantRatio, pitchMedian, rangeFactor, 1.0
    Save as WAV file: outFile$
    """.write(to: script, atomically: true, encoding: .utf8)
    let flippedVocal = scratch.appendingPathComponent("vocal-flipped.wav")
    let median = recipe.praatPitchMedian(detectedF0: track.voice?.medianF0)
    let praat = try await runCommandAt(
      FlipTools.praatBinary,
      [
        "--run", script.path, vocalMono.path, flippedVocal.path,
        fmt(recipe.formantRatio), fmt(median), fmt(recipe.pitchRangeFactor),
      ])
    guard praat.code == 0, fm.fileExists(atPath: flippedVocal.path) else {
      throw ProcessError.failed(tool: "praat", stderr: tailError(praat.stderrString))
    }

    // optional grit/polish on the vocal stem alone — the instrumental stays dry
    var vocalFinal = flippedVocal
    if let filter = flipEncodeFilter(recipe) {
      let treated = scratch.appendingPathComponent("vocal-treated.wav")
      try await ffmpegStep(["-i", flippedVocal.path, "-af", filter, treated.path])
      vocalFinal = treated
    }

    // remix at unity gain; back to the playable's sample rate so the deck can
    // swap files without a format change
    let tmp = scratch.appendingPathComponent("flipped.m4a")
    try await ffmpegStep([
      "-i", vocalFinal.path, "-i", instrumental.path,
      "-filter_complex",
      "[0:a]aformat=channel_layouts=stereo[v];[v][1:a]amix=inputs=2:normalize=0[out]",
      "-map", "[out]", "-ar", String(Int(track.sampleRate)), "-c:a", "alac", tmp.path,
    ])
    try? fm.removeItem(at: dest)
    try fm.moveItem(at: tmp, to: dest)
  }

  /// The post-shift treatment chain: grit (rasp exciter) first, then polish
  /// (chorus/echo space). nil when the recipe wants neither.
  private func flipEncodeFilter(_ recipe: VocalFlipRecipe) -> String? {
    var parts: [String] = []
    if recipe.grit { parts.append(buildFlipGritFilter()) }
    if recipe.polish { parts.append(buildFlipPolishFilter()) }
    return parts.isEmpty ? nil : parts.joined(separator: ",")
  }

  private func ffmpegStep(_ args: [String]) async throws {
    try await step("ffmpeg", ["-hide_banner", "-nostats", "-y"] + args)
  }

  private func step(_ tool: String, _ args: [String]) async throws {
    let result = try await runCommand(tool, args)
    guard result.code == 0 else {
      throw ProcessError.failed(tool: tool, stderr: tailError(result.stderrString))
    }
  }

  private func fmt(_ semitones: Double) -> String { String(format: "%.4f", semitones) }
}
