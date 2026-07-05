import Foundation

/// Resolved metadata for a track (before the audio is pulled).
public struct TrackMeta: Codable, Equatable, Sendable {
  /// Stable cache key: `${extractor}-${id}`, sanitized.
  public var key: String
  public var title: String
  public var artist: String
  /// Seconds.
  public var duration: Double
  public var thumbnail: String?
  public var webpageURL: String
  /// yt-dlp extractor, e.g. "youtube" | "soundcloud".
  public var source: String

  public init(
    key: String, title: String, artist: String, duration: Double,
    thumbnail: String?, webpageURL: String, source: String
  ) {
    self.key = key
    self.title = title
    self.artist = artist
    self.duration = duration
    self.thumbnail = thumbnail
    self.webpageURL = webpageURL
    self.source = source
  }
}

/// A track whose audio is pulled into the local cache and ready to remix.
public struct TrackInfo: Codable, Equatable, Sendable, Identifiable {
  public var meta: TrackMeta
  /// Absolute path of the cached original (native codec, max quality).
  public var originalPath: String
  /// Absolute path of a PCM/ALAC copy the audio engine can decode + scrub.
  public var playablePath: String
  /// Absolute path of cached cover art, if any.
  public var artPath: String?
  /// Native sample rate of the original.
  public var sampleRate: Double
  /// Integrated loudness (LUFS) of the original, measured once at pull time. Used
  /// for ReplayGain-style makeup gain (live + export). Resample-invariant, so one
  /// measurement is valid for every preset/speed. Optional for older cache entries.
  public var loudnessI: Double?
  /// Detected beat grid (BPM + phase), measured once at pull time. Drives the
  /// beatmatched automix. nil if undetectable or an older cache entry.
  public var beat: Tempo.Beat?
  /// Detected vocal register (median F0 + gender), measured once at pull time.
  /// Gates the vocal flip. nil if undecodable or an older cache entry.
  public var voice: Voice.Analysis?

  public var id: String { meta.key }

  /// Per-track makeup gain in dB toward the target loudness, clamped to ±12 dB.
  public func makeupGainDB(target: Double = -14) -> Double {
    guard let loudnessI else { return 0 }
    return max(-12, min(12, target - loudnessI))
  }

  public init(
    meta: TrackMeta, originalPath: String, playablePath: String,
    artPath: String?, sampleRate: Double, loudnessI: Double? = nil, beat: Tempo.Beat? = nil,
    voice: Voice.Analysis? = nil
  ) {
    self.meta = meta
    self.originalPath = originalPath
    self.playablePath = playablePath
    self.artPath = artPath
    self.sampleRate = sampleRate
    self.loudnessI = loudnessI
    self.beat = beat
    self.voice = voice
  }
}
