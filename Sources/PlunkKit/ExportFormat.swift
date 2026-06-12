import Foundation

/// Output container/codec for an exported remix.
// Declaration order = picker order: descending quality/size tiers.
public enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
  case flac
  case wav
  case mp3
  case mp3v0
  case opus

  public var id: String { rawValue }

  /// Human, tier-first label for the format picker (quality concept → format/spec).
  public var label: String {
    switch self {
    case .flac: "Lossless (FLAC)"
    case .wav: "Uncompressed (WAV)"
    case .mp3: "High quality (MP3 320k)"
    case .mp3v0: "Balanced (MP3 V0)"
    case .opus: "Compact (Opus 192k)"
    }
  }

  public var ext: String {
    switch self {
    case .mp3, .mp3v0: "mp3"
    case .flac: "flac"
    case .wav: "wav"
    case .opus: "opus"
    }
  }

  /// Encoder arguments for ffmpeg.
  public var encoderArgs: [String] {
    switch self {
    case .mp3: ["-c:a", "libmp3lame", "-b:a", "320k", "-id3v2_version", "3"]
    case .mp3v0: ["-c:a", "libmp3lame", "-q:a", "0", "-id3v2_version", "3"]
    case .flac: ["-c:a", "flac", "-compression_level", "8"]
    case .wav: ["-c:a", "pcm_s16le"]
    case .opus: ["-c:a", "libopus", "-b:a", "192k"]
    }
  }

  /// opus/ogg and wav can't carry an embedded cover-art video stream.
  public var supportsCoverArt: Bool {
    switch self {
    case .mp3, .mp3v0, .flac: true
    case .wav, .opus: false
    }
  }
}
