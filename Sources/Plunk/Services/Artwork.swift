import Foundation

/// Looks up official square album art via the iTunes Search API (free, no key) so
/// the disc covers / cards show real cover art instead of a 16:9 YouTube thumbnail.
enum Artwork {
  /// A high-res cover-art URL for the track, or nil if iTunes has no match.
  static func officialCover(artist: String, title: String) async -> String? {
    let term = cleanTerm(artist: artist, title: title)
    guard !term.isEmpty, var comps = URLComponents(string: "https://itunes.apple.com/search")
    else { return nil }
    comps.queryItems = [
      .init(name: "term", value: term),
      .init(name: "entity", value: "song"),
      .init(name: "limit", value: "1"),
    ]
    guard let url = comps.url else { return nil }
    do {
      let (data, resp) = try await URLSession.shared.data(from: url)
      guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
      guard let art = try JSONDecoder().decode(Response.self, from: data).results.first?.artworkUrl100
      else { return nil }
      // the API hands back a 100×100 thumb; bump the dimensions for a crisp label
      return art.replacingOccurrences(of: "100x100bb", with: "600x600bb")
    } catch {
      return nil
    }
  }

  private struct Response: Decodable {
    struct Item: Decodable { let artworkUrl100: String? }
    let results: [Item]
  }

  /// Strip the noise YouTube titles carry ("(Official Video)", "[Audio]", …) so the
  /// search matches the actual recording.
  private static func cleanTerm(artist: String, title: String) -> String {
    var t = title.replacingOccurrences(
      of: #"[\(\[].*?[\)\]]"#, with: "", options: .regularExpression)
    for noise in [
      "official music video", "official video", "official audio", "lyric video", "visualizer",
      "lyrics", "audio", "hd", "4k", "mv",
    ] {
      t = t.replacingOccurrences(of: noise, with: "", options: .caseInsensitive)
    }
    t = t.trimmingCharacters(in: .whitespacesAndNewlines)
    let combined = artist.isEmpty ? t : "\(artist) \(t)"
    return combined.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
