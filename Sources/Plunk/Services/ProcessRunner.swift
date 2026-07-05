import Foundation

struct CommandResult {
  let stdout: Data
  let stderr: Data
  let code: Int32

  var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
  var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

enum ProcessError: LocalizedError {
  /// A required tool (yt-dlp/ffmpeg/ffprobe) wasn't found on PATH.
  case notFound(String)
  case failed(tool: String, stderr: String)

  var errorDescription: String? {
    switch self {
    case let .notFound(name):
      "\(name) not found — install it with `brew install \(name == "ffprobe" ? "ffmpeg" : name)`"
    case let .failed(tool, stderr):
      stderr.isEmpty ? "\(tool) failed" : stderr
    }
  }
}

/// Locates command-line tools and builds an augmented PATH. A GUI app launched
/// from Finder inherits a minimal PATH that excludes Homebrew, so we search the
/// usual install dirs and pass them down to child processes (yt-dlp shells out
/// to `deno`/`ffmpeg`, which must also be findable).
enum Tools {
  // ~/.bun/bin is where Bun installs and is NOT on a Finder-launched app's PATH
  static var searchDirs: [String] {
    ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "\(NSHomeDirectory())/.bun/bin"]
  }

  static func childPath() -> String {
    let existing = ProcessInfo.processInfo.environment["PATH"]?
      .split(separator: ":").map(String.init) ?? []
    var seen = Set<String>()
    return (searchDirs + existing).filter { seen.insert($0).inserted }.joined(separator: ":")
  }

  static func locate(_ name: String) -> String? {
    let fm = FileManager.default
    for dir in childPath().split(separator: ":") {
      let path = "\(dir)/\(name)"
      if fm.isExecutableFile(atPath: path) { return path }
    }
    return nil
  }

  /// Tools that must be present for the app to function.
  /// `bun` is yt-dlp's JS runtime here (forced via --js-runtimes; see YtDlp).
  static func missing() -> [String] {
    ["yt-dlp", "ffmpeg", "ffprobe", "bun"].filter { locate($0) == nil }
  }
}

private func readToEnd(_ handle: FileHandle) async -> Data {
  await withCheckedContinuation { cont in
    DispatchQueue.global(qos: .userInitiated).async {
      let data = (try? handle.readToEnd()) ?? Data()
      cont.resume(returning: data)
    }
  }
}

/// Run a command, draining stdout/stderr concurrently (so large output — e.g.
/// yt-dlp's `-J` — never deadlocks on a full pipe buffer). Terminates the
/// process if the surrounding Task is cancelled.
func runCommand(_ tool: String, _ args: [String]) async throws -> CommandResult {
  guard let exe = Tools.locate(tool) else { throw ProcessError.notFound(tool) }
  return try await runCommandAt(exe, args)
}

/// Same, for an executable at a fixed path that isn't PATH-resolved (e.g. the
/// Praat cask binary inside its .app bundle).
func runCommandAt(_ exePath: String, _ args: [String]) async throws -> CommandResult {
  let proc = Process()
  proc.executableURL = URL(fileURLWithPath: exePath)
  proc.arguments = args
  var env = ProcessInfo.processInfo.environment
  env["PATH"] = Tools.childPath()
  proc.environment = env

  let outPipe = Pipe()
  let errPipe = Pipe()
  proc.standardOutput = outPipe
  proc.standardError = errPipe

  return try await withTaskCancellationHandler {
    async let out = readToEnd(outPipe.fileHandleForReading)
    async let err = readToEnd(errPipe.fileHandleForReading)
    // terminationHandler is set BEFORE launch so an exit can never be missed —
    // waitUntilExit's run-loop polling proved lossy (children exited, the wait
    // never woke) when several subprocesses run back-to-back off the main thread
    let code: Int32 = try await withCheckedThrowingContinuation { cont in
      proc.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
      do { try proc.run() } catch {
        proc.terminationHandler = nil
        cont.resume(throwing: error)
      }
    }
    let (stdout, stderr) = await (out, err)
    return CommandResult(stdout: stdout, stderr: stderr, code: code)
  } onCancel: {
    proc.terminate()
  }
}

/// The last few non-empty stderr lines — the useful part of a tool failure.
func tailError(_ stderr: String, lines: Int = 3) -> String {
  stderr.split(separator: "\n").map(String.init).filter { !$0.isEmpty }.suffix(lines)
    .joined(separator: " · ")
}
