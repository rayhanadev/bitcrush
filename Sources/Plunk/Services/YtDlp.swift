import Foundation
import PlunkKit

/// A subset of yt-dlp's `-J` output.
private struct YtEntry: Decodable {
  let id: String
  let title: String
  let extractor: String
  let uploader: String?
  let channel: String?
  let artist: String?
  let duration: Double?
  let thumbnail: String?
  let webpage_url: String

  func toMeta() -> TrackMeta {
    let key = "\(extractor)-\(id)".map { c -> Character in
      (c.isASCII && (c.isLetter || c.isNumber)) || c == "-" || c == "_" ? c : "_"
    }
    return TrackMeta(
      key: String(key),
      title: title,
      // artist is only populated for YouTube Music content; fall back to channel
      artist: artist ?? uploader ?? channel ?? "unknown",
      duration: duration ?? 0,
      thumbnail: thumbnail,
      webpageURL: webpage_url,
      source: extractor)
  }
}

/// Search results come wrapped as `{ _type: "playlist", entries: [...] }`.
private struct YtSearchResult: Decodable {
  let entries: [YtEntry]?
}

/// A lightweight `--flat-playlist` search entry (used to score candidates cheaply
/// before fully extracting just the winner).
private struct FlatSearch: Decodable {
  struct Entry: Decodable {
    let title: String?
    let url: String?
    let duration: Double?
    let channel: String?
    let uploader: String?
  }
  let entries: [Entry]?
}

struct YtDlp: Sendable {
  /// Optional Netscape cookies.txt — helps past YouTube bot-checks if needed.
  var cookiesPath: String?

  private var commonFlags: [String] {
    var flags = ["--no-playlist", "--no-warnings"]
    // force Bun as yt-dlp's JS runtime for YouTube challenges, overriding the deno
    // default (--no-js-runtimes clears defaults; then enable bun by explicit path)
    if let bun = Tools.locate("bun") {
      flags += ["--no-js-runtimes", "--js-runtimes", "bun:\(bun)"]
    }
    if let cookiesPath, !cookiesPath.isEmpty { flags += ["--cookies", cookiesPath] }
    return flags
  }

  private func isURL(_ s: String) -> Bool {
    s.lowercased().hasPrefix("http://") || s.lowercased().hasPrefix("https://")
  }

  /// Resolve a URL or free-text search to track metadata, without downloading.
  /// For searches, fetch several candidates and pick the **official** recording
  /// (using artist/duration hints when known), then fully extract just that one.
  func resolve(_ query: String, artist: String? = nil, expectedDuration: Double? = nil)
    async throws -> TrackMeta
  {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if isURL(trimmed) { return try await extract(trimmed) }

    let candidates = (try? await searchCandidates(trimmed, limit: 6)) ?? []
    let best =
      candidates
      .max {
        officialScore(for: $0.1, artist: artist, expectedDuration: expectedDuration, query: trimmed)
          < officialScore(
            for: $1.1, artist: artist, expectedDuration: expectedDuration, query: trimmed)
      }?.0
    // fall back to a plain top result if scoring found nothing usable
    return try await extract(best ?? "ytsearch1:\(trimmed)")
  }

  /// Flatly list search candidates as (url, scoring-candidate) pairs — cheap, no
  /// per-result deep extraction.
  private func searchCandidates(_ query: String, limit: Int) async throws
    -> [(String, TrackCandidate)]
  {
    let result = try await runCommand(
      "yt-dlp", commonFlags + ["--flat-playlist", "-J", "ytsearch\(limit):\(query)"])
    guard result.code == 0 else {
      throw ProcessError.failed(tool: "yt-dlp", stderr: tailError(result.stderrString))
    }
    let flat = try JSONDecoder().decode(FlatSearch.self, from: result.stdout)
    return (flat.entries ?? []).compactMap { entry in
      guard let url = entry.url, let title = entry.title else { return nil }
      return (
        url,
        TrackCandidate(
          title: title, channel: entry.channel ?? entry.uploader ?? "",
          durationSeconds: entry.duration)
      )
    }
  }

  /// Fully extract metadata for a URL or `ytsearchN:` target.
  private func extract(_ target: String) async throws -> TrackMeta {
    let result = try await runCommand("yt-dlp", commonFlags + ["-J", target])
    guard result.code == 0 else {
      throw ProcessError.failed(tool: "yt-dlp", stderr: tailError(result.stderrString))
    }
    let decoder = JSONDecoder()
    if let search = try? decoder.decode(YtSearchResult.self, from: result.stdout),
      let first = search.entries?.first
    {
      return first.toMeta()
    }
    guard let entry = try? decoder.decode(YtEntry.self, from: result.stdout) else {
      throw ProcessError.failed(tool: "yt-dlp", stderr: "no results found")
    }
    return entry.toMeta()
  }

  /// Download the highest-quality audio (native codec, no transcode) into `dir`.
  /// Returns the final file path printed by yt-dlp.
  func pull(_ meta: TrackMeta, into dir: URL) async throws -> String {
    let result = try await runCommand(
      "yt-dlp",
      commonFlags + [
        "-f", "bestaudio/best",
        "-P", dir.path,
        "-o", "%(extractor)s-%(id)s.%(ext)s",
        "-N", "4", "-q", "--no-progress",
        "--print", "after_move:filepath",
        meta.webpageURL,
      ])
    guard result.code == 0 else {
      throw ProcessError.failed(tool: "yt-dlp", stderr: tailError(result.stderrString))
    }
    let path = result.stdoutString
      .split(separator: "\n").last.map(String.init)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
      throw ProcessError.failed(tool: "yt-dlp", stderr: "no audio file produced")
    }
    return path
  }
}
