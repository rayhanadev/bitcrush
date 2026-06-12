import Foundation
import PlunkKit

/// Orchestrates yt-dlp + ffmpeg + cache into the two high-level operations the
/// UI needs: resolve a query to metadata, and pull a track ready to play/export.
struct Library: Sendable {
  let cache: Cache
  let ytdlp: YtDlp
  let ffmpeg = FFmpeg()

  func resolve(_ query: String, artist: String? = nil, expectedDuration: Double? = nil)
    async throws -> TrackMeta
  {
    try await ytdlp.resolve(query, artist: artist, expectedDuration: expectedDuration)
  }

  func pull(_ meta: TrackMeta) async throws -> TrackInfo {
    // reuse a previously pulled track whose files still exist
    if let cached = cache.existing(key: meta.key) { return cached }

    let original = try await ytdlp.pull(meta, into: cache.tracksDir)
    let (duration, sampleRate) = try await ffmpeg.probe(original)

    let playable = cache.tracksDir.appendingPathComponent("\(meta.key).m4a")

    // measure loudness + look up official cover art concurrently with the transcode
    async let loudness = ffmpeg.measureLoudness(original)
    async let officialArt = Artwork.officialCover(artist: meta.artist, title: meta.title)
    if !FileManager.default.fileExists(atPath: playable.path) {
      try await ffmpeg.transcodePlayable(original: original, to: playable)
    }
    let loudnessI = await loudness

    // detect the beat grid for the automixer — CPU-bound, overlapped with the art fetch
    let playablePath = playable.path
    async let beat = Task.detached(priority: .utility) {
      BeatAnalyzer.analyze(path: playablePath)
    }.value

    var resolved = meta
    if duration > 0 { resolved.duration = duration }
    // prefer official square album art; fall back to the source thumbnail
    if let official = await officialArt { resolved.thumbnail = official }
    let art = await downloadArt(resolved)

    let track = TrackInfo(
      meta: resolved,
      originalPath: original,
      playablePath: playable.path,
      artPath: art?.path,
      sampleRate: sampleRate,
      loudnessI: loudnessI,
      beat: await beat)
    cache.remember(track)
    return track
  }

  /// Fetch cover art over http(s) only. Best-effort — art is optional.
  private func downloadArt(_ meta: TrackMeta) async -> URL? {
    guard let thumb = meta.thumbnail, let url = URL(string: thumb),
      url.scheme == "http" || url.scheme == "https"
    else { return nil }
    do {
      let (data, response) = try await URLSession.shared.data(from: url)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty,
        response.mimeType?.hasPrefix("image/") == true  // skip HTML error pages etc.
      else { return nil }
      let dest = cache.artDir.appendingPathComponent("\(meta.key).img")
      try data.write(to: dest, options: .atomic)
      return dest
    } catch {
      return nil
    }
  }
}
