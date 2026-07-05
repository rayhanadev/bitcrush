import Foundation
import PlunkKit

/// Local cache under ~/Library/Application Support/plunk: pulled originals,
/// playable copies, cover art, and a small recent-tracks registry.
struct Cache: Sendable {
  let root: URL
  let tracksDir: URL
  let rendersDir: URL
  let artDir: URL
  let flipsDir: URL

  init() {
    let base =
      (try? FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    root = base.appendingPathComponent("plunk", isDirectory: true)
    tracksDir = root.appendingPathComponent("tracks", isDirectory: true)
    rendersDir = root.appendingPathComponent("renders", isDirectory: true)
    artDir = root.appendingPathComponent("art", isDirectory: true)
    flipsDir = root.appendingPathComponent("flips", isDirectory: true)
    for dir in [tracksDir, rendersDir, artDir, flipsDir] {
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    sweepOrphanFlips()
  }

  /// Delete flip intermediates whose parent track is gone — recipe churn while
  /// experimenting would otherwise accumulate stale variants forever.
  private func sweepOrphanFlips() {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: flipsDir.path)) ?? []
    guard !names.isEmpty else { return }
    let keys = Set(loadRecent().map(\.meta.key))
    for name in names {
      guard let range = name.range(of: "-flip-") else { continue }
      if !keys.contains(String(name[..<range.lowerBound])) {
        try? FileManager.default.removeItem(at: flipsDir.appendingPathComponent(name))
      }
    }
  }

  private var recentFile: URL { root.appendingPathComponent("recent.json") }

  /// Recent tracks whose cached files still exist (prunes stale rows).
  func loadRecent() -> [TrackInfo] {
    guard let data = try? Data(contentsOf: recentFile),
      let tracks = try? JSONDecoder().decode([TrackInfo].self, from: data)
    else { return [] }
    return tracks.filter {
      FileManager.default.fileExists(atPath: $0.originalPath)
        && FileManager.default.fileExists(atPath: $0.playablePath)
    }
  }

  /// Prepend a track (most-recently-used first), evict the tail past the count/size
  /// budget — deleting the evicted tracks' cached files so the cache stays bounded
  /// (Spotify-style LRU) — persist, and return the new list.
  @discardableResult
  func remember(_ track: TrackInfo, limit: Int = 50, maxBytes: Int64 = 3_000_000_000) -> [TrackInfo]
  {
    let previous = loadRecent()
    var list = previous.filter { $0.meta.key != track.meta.key }
    list.insert(track, at: 0)

    // keep MRU entries until we hit either the count or the byte budget; a
    // track's flip intermediates count against its budget (they die with it)
    let flipNames = (try? FileManager.default.contentsOfDirectory(atPath: flipsDir.path)) ?? []
    func flipBytes(_ key: String) -> Int64 {
      flipNames.filter { $0.hasPrefix("\(key)-flip-") }
        .reduce(0) { $0 + fileSize(flipsDir.appendingPathComponent($1).path) }
    }
    var kept: [TrackInfo] = []
    var bytes: Int64 = 0
    for t in list {
      guard kept.count < limit else { break }
      let size = fileSize(t.originalPath) + fileSize(t.playablePath) + flipBytes(t.meta.key)
      if !kept.isEmpty, bytes + size > maxBytes { break }
      bytes += size
      kept.append(t)
    }

    // delete cached files for anything that fell out of the window
    let keptKeys = Set(kept.map(\.meta.key))
    for t in previous where !keptKeys.contains(t.meta.key) { evictFiles(t) }

    if let data = try? JSONEncoder().encode(kept) {
      try? data.write(to: recentFile, options: .atomic)  // never leave a truncated file
    }
    return kept
  }

  private func fileSize(_ path: String) -> Int64 {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
      let size = attrs[.size] as? NSNumber
    else { return 0 }
    return size.int64Value
  }

  /// Remove an evicted track's cached files (only ones inside our cache root).
  private func evictFiles(_ track: TrackInfo) {
    for path in [track.originalPath, track.playablePath, track.artPath].compactMap({ $0 })
    where path.hasPrefix(root.path) {
      try? FileManager.default.removeItem(atPath: path)
    }
    let prefix = "\(track.meta.key)-flip-"
    for name in (try? FileManager.default.contentsOfDirectory(atPath: flipsDir.path)) ?? []
    where name.hasPrefix(prefix) {
      try? FileManager.default.removeItem(at: flipsDir.appendingPathComponent(name))
    }
  }

  /// A cached track for this key with valid files, if present.
  func existing(key: String) -> TrackInfo? {
    loadRecent().first { $0.meta.key == key }
  }
}
