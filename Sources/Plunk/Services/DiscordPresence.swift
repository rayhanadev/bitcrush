import Darwin
import Foundation

/// Publishes a Discord Rich Presence ("Listening to Bitcrush<3 — …") by talking to the
/// local Discord desktop client over its IPC socket. No bot, no token, no network —
/// the user's own client renders the status. Silent no-op if Discord isn't running.
///
/// Wire protocol: a Unix-domain socket at `$TMPDIR/discord-ipc-{0…9}`; each packet is
/// `[UInt32 op LE][UInt32 len LE][JSON]`. op 0 = handshake, op 1 = frame (commands).
final class DiscordPresence: @unchecked Sendable {
  /// The Discord application ("Bitcrush<3") this presence is attributed to.
  static let clientID = "1514746027180298414"

  struct State: Sendable {
    var title: String
    var artist: String
    var vibe: String
    var artURL: String?
    var isPlaying: Bool
    var elapsed: Double
    var duration: Double
  }

  private let queue = DispatchQueue(label: "dev.bitcrush.discord")
  private var fd: Int32 = -1
  private var connected = false
  private var enabled = true
  private var current: State?
  private var lastConnectAttempt = Date.distantPast
  private var lastSent = Date.distantPast
  private var pending: DispatchWorkItem?

  // MARK: public API (thread-safe — everything hops onto `queue`)

  func setEnabled(_ on: Bool) {
    queue.async {
      guard self.enabled != on else { return }
      self.enabled = on
      if on {
        self.pushLocked()
      } else {
        self.clearLocked()
        self.disconnectLocked()
      }
    }
  }

  /// Update (debounced) the presence to reflect what's playing.
  func update(_ state: State) {
    queue.async {
      self.current = state
      guard self.enabled else { return }
      self.pending?.cancel()
      let work = DispatchWorkItem { [weak self] in self?.pushLocked() }
      self.pending = work
      self.queue.asyncAfter(deadline: .now() + 1.2, execute: work)  // coalesce bursts
    }
  }

  /// Remove the presence (track stopped / nothing playing).
  func clear() {
    queue.async {
      self.current = nil
      self.pending?.cancel()
      self.clearLocked()
    }
  }

  // MARK: queue-isolated send

  private func pushLocked() {
    guard enabled, let s = current else { return }
    // honor Discord's ~5-updates-per-20s ceiling: defer if we sent recently
    let since = Date().timeIntervalSince(lastSent)
    if since < 4 {
      pending?.cancel()
      let work = DispatchWorkItem { [weak self] in self?.pushLocked() }
      pending = work
      queue.asyncAfter(deadline: .now() + (4 - since), execute: work)
      return
    }
    guard ensureConnectedLocked() else { return }
    if sendActivityLocked(s) {
      lastSent = Date()
    } else {
      disconnectLocked()  // try a fresh socket next time
    }
  }

  private func sendActivityLocked(_ s: State) -> Bool {
    let pid = Int(ProcessInfo.processInfo.processIdentifier)
    var activity: [String: Any] = ["type": 2]  // 2 = Listening
    let details = clamp(s.title)
    if let details { activity["details"] = details }
    let line = s.artist.isEmpty ? s.vibe : "\(s.artist) · \(s.vibe)"
    if let state = clamp(line) { activity["state"] = state }
    if s.isPlaying, s.duration > 1 {
      let nowMs = Int(Date().timeIntervalSince1970 * 1000)
      let startMs = nowMs - Int(max(0, s.elapsed) * 1000)
      activity["timestamps"] = ["start": startMs, "end": startMs + Int(s.duration * 1000)]
    }
    if let art = s.artURL, art.hasPrefix("http") {
      activity["assets"] = ["large_image": art]  // no large_text — avoids a duplicate line
    }
    let cmd: [String: Any] = [
      "cmd": "SET_ACTIVITY",
      "args": ["pid": pid, "activity": activity],
      "nonce": UUID().uuidString,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: cmd) else { return false }
    drainLocked()
    return writeFrameLocked(op: 1, json: data)
  }

  private func clearLocked() {
    guard connected else { return }
    let pid = Int(ProcessInfo.processInfo.processIdentifier)
    let cmd: [String: Any] = [
      "cmd": "SET_ACTIVITY",
      "args": ["pid": pid, "activity": NSNull()],
      "nonce": UUID().uuidString,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: cmd) {
      if !writeFrameLocked(op: 1, json: data) { disconnectLocked() }
    }
  }

  /// Discord wants details/state in 2…128 chars; drop too-short, truncate too-long.
  private func clamp(_ s: String) -> String? {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard t.count >= 2 else { return nil }
    return String(t.prefix(128))
  }

  // MARK: connection

  private func ensureConnectedLocked() -> Bool {
    if connected, fd >= 0 { return true }
    if Date().timeIntervalSince(lastConnectAttempt) < 8 { return false }  // throttle retries
    lastConnectAttempt = Date()
    for path in Self.candidatePaths() {
      guard let f = Self.openUnixSocket(path) else { continue }
      fd = f
      if handshakeLocked() {
        connected = true
        return true
      }
      Darwin.close(fd)
      fd = -1
    }
    return false
  }

  private func handshakeLocked() -> Bool {
    let payload: [String: Any] = ["v": 1, "client_id": Self.clientID]
    guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return false }
    guard writeFrameLocked(op: 0, json: data) else { return false }
    // WAIT for the READY frame before returning — sending SET_ACTIVITY before Discord
    // has processed the handshake gets it silently dropped (the "nothing shows" bug).
    return awaitFrameLocked()
  }

  /// Block (on the worker queue) up to ~2s for one full frame — Discord's READY reply.
  private func awaitFrameLocked() -> Bool {
    guard fd >= 0 else { return false }
    let deadline = Date().addingTimeInterval(2)
    var header = [UInt8](repeating: 0, count: 8)
    var got = 0
    while Date() < deadline {
      let n = Darwin.read(fd, &header[got], 8 - got)
      if n > 0 {
        got += n
        if got == 8 {
          let len = Int(
            UInt32(header[4]) | (UInt32(header[5]) << 8) | (UInt32(header[6]) << 16)
              | (UInt32(header[7]) << 24))
          var body = [UInt8](repeating: 0, count: max(1, len))
          var read = 0
          while read < len, Date() < deadline {
            let k = Darwin.read(fd, &body[read], len - read)
            if k > 0 { read += k } else { usleep(5000) }
          }
          return true  // got the READY → Discord is ready for SET_ACTIVITY
        }
      } else {
        usleep(10000)  // nothing yet
      }
    }
    return false  // no reply — bad client_id / not really Discord
  }

  private func disconnectLocked() {
    if fd >= 0 { Darwin.close(fd) }
    fd = -1
    connected = false
  }

  /// All the places Discord may place its IPC socket, in priority order.
  private static func candidatePaths() -> [String] {
    let env = ProcessInfo.processInfo.environment
    var bases = [env["XDG_RUNTIME_DIR"], env["TMPDIR"], env["TMP"], env["TEMP"], "/tmp"]
      .compactMap { $0 }
    // Discord may also nest under an app-group folder inside the temp dir
    if let tmp = env["TMPDIR"] { bases.append(tmp + "app/com.hnc.Discord") }
    return bases.flatMap { base -> [String] in
      let dir = base.hasSuffix("/") ? String(base.dropLast()) : base
      return (0...9).map { "\(dir)/discord-ipc-\($0)" }
    }
  }

  private static func openUnixSocket(_ path: String) -> Int32? {
    let f = socket(AF_UNIX, SOCK_STREAM, 0)
    guard f >= 0 else { return nil }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let ok = path.withCString { cstr -> Bool in
      withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        let n = strlen(cstr)
        guard n < raw.count else { return false }
        memcpy(raw.baseAddress!, cstr, n + 1)
        return true
      }
    }
    guard ok else { Darwin.close(f); return nil }
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let r = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(f, $0, size) }
    }
    guard r == 0 else { Darwin.close(f); return nil }
    _ = fcntl(f, F_SETFL, O_NONBLOCK)  // non-blocking: reads drain, never hang the queue
    return f
  }

  // MARK: framing

  private func writeFrameLocked(op: UInt32, json: Data) -> Bool {
    guard fd >= 0 else { return false }
    var header = Data(capacity: 8)
    var o = op.littleEndian
    var len = UInt32(json.count).littleEndian
    withUnsafeBytes(of: &o) { header.append(contentsOf: $0) }
    withUnsafeBytes(of: &len) { header.append(contentsOf: $0) }
    let packet = header + json
    return packet.withUnsafeBytes { buf -> Bool in
      guard let base = buf.baseAddress else { return false }
      var total = 0
      while total < packet.count {
        let n = Darwin.write(fd, base + total, packet.count - total)
        if n > 0 {
          total += n
        } else if n < 0, errno == EAGAIN {
          continue  // socket buffer full — spin briefly
        } else {
          return false
        }
      }
      return true
    }
  }

  /// Discard anything the client sent us (READY / command replies) — non-blocking.
  private func drainLocked() {
    guard fd >= 0 else { return }
    var buf = [UInt8](repeating: 0, count: 4096)
    while Darwin.read(fd, &buf, buf.count) > 0 {}
  }

  #if DEBUG
  /// Synchronously connect + push a test activity, reporting each step (BITCRUSH_DISCORD).
  func debugProbe() -> String {
    queue.sync {
      var out = "TMPDIR=\(ProcessInfo.processInfo.environment["TMPDIR"] ?? "nil")\n"
      let found = Self.candidatePaths().filter { FileManager.default.fileExists(atPath: $0) }
      out += "sockets: \(found.isEmpty ? "NONE FOUND" : found.joined(separator: ", "))\n"
      enabled = true
      current = State(
        title: "Lovefield", artist: "underscores", vibe: "nightcore + bitcrush", artURL: nil,
        isPlaying: true, elapsed: 30, duration: 185)
      guard ensureConnectedLocked() else { return out + "connect/handshake FAILED" }
      out += "connected + READY ✓\n"
      return out + (sendActivityLocked(current!) ? "SET_ACTIVITY sent ✓" : "SET_ACTIVITY FAILED")
    }
  }
  #endif
}
