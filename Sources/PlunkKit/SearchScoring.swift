import Foundation

/// A YouTube search candidate, scored to find the *official* studio recording
/// (not a live version, remix, cover, sped-up edit, reupload, etc.).
public struct TrackCandidate: Sendable {
  public let title: String
  /// Channel or uploader name.
  public let channel: String
  public let durationSeconds: Double?

  public init(title: String, channel: String, durationSeconds: Double?) {
    self.title = title
    self.channel = channel
    self.durationSeconds = durationSeconds
  }
}

private func alphanumeric(_ s: String) -> String {
  String(String.UnicodeScalarView(s.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains)))
}

/// Variants we never want when the user asked for the official song. Skipped as a
/// penalty if the query itself contains the word (e.g. they searched for a remix).
private let unwantedKeywords = [
  "live", "remix", "cover", "sped up", "spedup", "slowed", "nightcore", "8d",
  "instrumental", "karaoke", "lyric", "reaction", "mashup", "bass boost",
  "extended", "loop", "1 hour", "hour loop", "tutorial", "reverb", "acoustic",
  "concert", "session", "demo",
]

/// Higher = more likely to be the official artist recording. Combine:
/// auto-generated "- Topic" / artist-owned channel, official-audio markers,
/// keyword penalties, and (when known) a match to the expected duration.
public func officialScore(
  for candidate: TrackCandidate, artist: String?, expectedDuration: Double?, query: String
) -> Double {
  let title = candidate.title.lowercased()
  let channel = candidate.channel.lowercased()
  let q = query.lowercased()
  var score = 0.0

  // auto-generated "Artist - Topic" channels host label-provided official audio
  if channel.hasSuffix("- topic") || channel.hasSuffix("-topic") { score += 50 }

  // channel is (or contains) the artist's name
  if let artist, !artist.isEmpty {
    let a = alphanumeric(artist)
    let c = alphanumeric(channel.replacingOccurrences(of: "- topic", with: ""))
    if !a.isEmpty, !c.isEmpty {
      if c == a {
        score += 35
      } else if c.contains(a) || a.contains(c) {
        score += 22
      }
    }
  }

  // explicit official markers
  if title.contains("official audio") || title.contains("official music video")
    || title.contains("official video")
  {
    score += 14
  }

  // penalize non-official variants, unless the query explicitly asked for one
  for word in unwantedKeywords where title.contains(word) && !q.contains(word) {
    score -= 30
  }

  // match the known (e.g. Apple Music) duration — a strong signal for the album cut
  if let expectedDuration, expectedDuration > 0, let d = candidate.durationSeconds, d > 0 {
    let diff = abs(d - expectedDuration)
    if diff <= 3 {
      score += 40
    } else if diff <= 8 {
      score += 22
    } else if diff <= 20 {
      score += 6
    } else {
      score -= min(45, diff / 4)
    }
  }

  return score
}
