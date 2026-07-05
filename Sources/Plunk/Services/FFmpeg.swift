import Foundation
import PlunkKit

struct FFmpeg: Sendable {
  private struct Probe: Decodable {
    struct Format: Decodable { let duration: String? }
    struct Stream: Decodable { let sample_rate: String? }
    let format: Format?
    let streams: [Stream]?
  }

  func probe(_ path: String) async throws -> (duration: Double, sampleRate: Double) {
    let result = try await runCommand(
      "ffprobe",
      ["-v", "error", "-show_entries", "format=duration:stream=sample_rate", "-of", "json", path])
    guard result.code == 0, let probe = try? JSONDecoder().decode(Probe.self, from: result.stdout)
    else {
      throw ProcessError.failed(tool: "ffprobe", stderr: tailError(result.stderrString))
    }
    let duration = Double(probe.format?.duration ?? "") ?? 0
    let sampleRate = probe.streams?.compactMap { $0.sample_rate }.first.flatMap(Double.init) ?? 48000
    return (duration, sampleRate)
  }

  /// Measure the original's integrated loudness (LUFS) via a one-pass loudnorm scan.
  /// Returns nil on failure (loudness normalization is then skipped, best-effort).
  func measureLoudness(_ path: String) async -> Double? {
    let result = try? await runCommand(
      "ffmpeg",
      [
        "-hide_banner", "-nostats", "-i", path,
        "-af", "loudnorm=I=-14:TP=-1:LRA=11:print_format=json", "-f", "null", "-",
      ])
    guard let result, result.code == 0 else { return nil }
    // the JSON block is printed to stderr; pull "input_i" out of it
    let text = result.stderrString
    guard let range = text.range(of: "\"input_i\"") else { return nil }
    let after = text[range.upperBound...].drop { $0 != ":" }.dropFirst()
    let value = after.prefix { $0 != "," && $0 != "\n" && $0 != "}" }
      .trimmingCharacters(in: CharacterSet(charactersIn: " \""))
    return Double(value)
  }

  /// Losslessly transcode the original to ALAC the audio engine can decode + scrub
  /// (Core Audio can't read YouTube's opus/webm directly). Writes via a temp file +
  /// atomic move so a killed/failed ffmpeg never leaves a truncated `<key>.m4a` that
  /// the reuse check would later treat as valid.
  func transcodePlayable(original: String, to dest: URL) async throws {
    let tmp = dest.deletingLastPathComponent()
      .appendingPathComponent("transcode-\(UUID().uuidString).m4a")
    let result = try await runCommand(
      "ffmpeg",
      ["-hide_banner", "-nostats", "-y", "-i", original, "-map", "0:a:0", "-c:a", "alac", tmp.path])
    guard result.code == 0 else {
      try? FileManager.default.removeItem(at: tmp)
      throw ProcessError.failed(tool: "ffmpeg", stderr: tailError(result.stderrString))
    }
    try? FileManager.default.removeItem(at: dest)
    try FileManager.default.moveItem(at: tmp, to: dest)
  }

  /// Render the remix to `dest` (via a temp file + atomic move, so a failed/killed
  /// ffmpeg never leaves a partial file at the user's chosen location). If the
  /// cover-art embed fails (e.g. an exotic/undecodable thumbnail), retry without it
  /// so the export still succeeds — losing the art beats failing the whole export.
  /// `sourceOverride` renders from an alternate source file (e.g. the vocal-flip
  /// intermediate) instead of the cached original.
  func render(
    track: TrackInfo, params: RemixParams, format: ExportFormat, scratchDir: URL, to dest: URL,
    sourceOverride: String? = nil
  ) async throws {
    let canEmbedArt = track.artPath != nil && format.supportsCoverArt
    do {
      try await runRender(
        track: track, params: params, format: format, scratchDir: scratchDir, to: dest,
        embedArt: canEmbedArt, sourceOverride: sourceOverride)
    } catch {
      guard canEmbedArt else { throw error }
      try await runRender(
        track: track, params: params, format: format, scratchDir: scratchDir, to: dest,
        embedArt: false, sourceOverride: sourceOverride)
    }
  }

  private func runRender(
    track: TrackInfo, params: RemixParams, format: ExportFormat, scratchDir: URL, to dest: URL,
    embedArt: Bool, sourceOverride: String? = nil
  ) async throws {
    let tmp = scratchDir.appendingPathComponent("render-\(UUID().uuidString).\(format.ext)")

    var args = ["-hide_banner", "-nostats", "-y", "-i", sourceOverride ?? track.originalPath]
    if embedArt, let art = track.artPath { args += ["-i", art] }
    args += ["-map", "0:a:0"]
    if embedArt {
      args += ["-map", "1:v:0", "-c:v", "mjpeg", "-q:v", "4", "-disposition:v:0", "attached_pic"]
    }
    let gain = track.loudnessI != nil ? track.makeupGainDB() : nil
    var filter = buildAudioFilter(params, sampleRate: Int(track.sampleRate), loudnessGainDB: gain)
    // noise-shaped dither only when truncating to 16-bit PCM (wav); flac keeps depth,
    // mp3/opus are lossy
    if format == .wav {
      filter += ",aresample=\(Int(track.sampleRate)):dither_method=triangular_hp"
    }
    args += [
      "-metadata", "title=\(track.meta.title)",
      "-metadata", "artist=\(track.meta.artist)",
      "-af", filter,
    ]
    args += format.encoderArgs
    args.append(tmp.path)

    let result = try await runCommand("ffmpeg", args)
    guard result.code == 0 else {
      try? FileManager.default.removeItem(at: tmp)
      throw ProcessError.failed(tool: "ffmpeg", stderr: tailError(result.stderrString, lines: 2))
    }
    try? FileManager.default.removeItem(at: dest)
    try FileManager.default.moveItem(at: tmp, to: dest)
  }
}
