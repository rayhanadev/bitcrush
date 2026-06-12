import Foundation

enum AppleMusicError: LocalizedError {
  case nothingPlaying
  case notAuthorized
  case failed(String)

  var errorDescription: String? {
    switch self {
    case .nothingPlaying:
      "Nothing is playing in Apple Music."
    case .notAuthorized:
      "Bitcrush<3 needs permission to read Apple Music. Grant it in System Settings → Privacy & Security → Automation."
    case let .failed(message):
      "Couldn't read Apple Music: \(message)"
    }
  }
}

/// Reads / drives the Music app via Apple Events. (Apple Music audio is
/// FairPlay-DRM-protected and can't be decrypted by third-party apps — we only
/// use the title/artist to re-source the track from YouTube.)
enum AppleMusic {
  typealias Track = (title: String, artist: String, duration: Double?)

  /// What to do to Music's queue before reading the current track.
  enum Move: String { case stay, next, previous }

  /// The currently-selected track (playing or paused).
  static func currentTrack() throws -> Track {
    try parse(runScript(trackQuery(move: .stay)))
  }

  /// Advance Music's queue to the next track, keep it silent, and read it.
  static func advanceToNext() throws -> Track {
    try parse(runScript(trackQuery(move: .next)))
  }

  /// Step back to the previous track, keep it silent, and read it.
  static func goToPrevious() throws -> Track {
    try parse(runScript(trackQuery(move: .previous)))
  }

  /// Pause Music so it doesn't play over plunk's remix.
  static func pausePlayback() {
    _ = try? runScript("tell application \"Music\" to if it is running then pause")
  }

  // MARK: internals

  /// Builds a script that (optionally steps the queue, then) returns the current
  /// track's "name\tartist\tduration", or "" when nothing is loaded / not running.
  private static func trackQuery(move: Move) -> String {
    let step =
      switch move {
      case .stay: ""
      case .next: "next track\n      pause"
      case .previous: "previous track\n      pause"
      }
    return """
      tell application "Music"
        if it is not running then return ""
        \(step)
        try
          set t to current track
          return (get name of t) & character id 9 & (get artist of t) & character id 9 & (get duration of t)
        on error
          return ""
        end try
      end tell
      """
  }

  private static func runScript(_ source: String) throws -> String {
    guard let script = NSAppleScript(source: source) else {
      throw AppleMusicError.failed("could not build the query")
    }
    var errorInfo: NSDictionary?
    let result = script.executeAndReturnError(&errorInfo)
    if let errorInfo {
      let code = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
      if code == -1743 || code == -1744 { throw AppleMusicError.notAuthorized }
      throw AppleMusicError.failed(errorInfo[NSAppleScript.errorMessage] as? String ?? "error \(code)")
    }
    return (result.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func parse(_ value: String) throws -> Track {
    guard !value.isEmpty else { throw AppleMusicError.nothingPlaying }
    let parts = value.components(separatedBy: "\t")
    let title = parts.first ?? ""
    guard !title.isEmpty else { throw AppleMusicError.nothingPlaying }
    let artist = parts.count > 1 ? parts[1] : ""
    let duration = parts.count > 2 ? Double(parts[2]) : nil
    return (title, artist, duration)
  }
}
