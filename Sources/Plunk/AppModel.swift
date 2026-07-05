import AppKit
import PlunkKit
import SwiftUI

/// UserDefaults keys shared between AppModel and the Settings window.
enum PrefKey {
  static let preset = "defaultPreset"
  static let format = "defaultFormat"
  static let autoGrab = "autoGrabOnOpen"
  static let followQueue = "followAppleMusicQueue"
  static let discordPresence = "discordPresence"
  static let automix = "automixTransitions"
  static let flipEngine = "flipEngine"
  static let flipPitch = "flipPitch"
  static let flipFormant = "flipFormant"
  static let flipPolish = "flipPolish"
  static let flipGrit = "flipGrit"
}

/// Top-level state machine: resolve → pull → load into the engine, plus export.
@MainActor
final class AppModel: ObservableObject {
  enum Busy: Equatable { case resolving, pulling }

  @Published var query = ""
  @Published private(set) var busy: Busy?
  @Published private(set) var meta: TrackMeta?
  @Published private(set) var track: TrackInfo?
  @Published private(set) var recent: [TrackInfo] = []
  @Published private(set) var exporting = false
  @Published var errorMessage: String?

  @Published var params = Preset.nightcore.params!
  @Published private(set) var preset: Preset = .nightcore
  @Published var format: ExportFormat = .mp3

  /// The next queue track being prefetched / ready to play instantly.
  @Published private(set) var upNext: TrackMeta?
  @Published private(set) var upNextReady = false
  /// Apple Music's current track diverged from what plunk is playing.
  @Published private(set) var outOfSync = false

  /// Non-nil when a required CLI tool is missing — shown as a setup banner.
  let setupError: String?

  /// Vocal-flip lifecycle for the current track. `.on` carries the flipped
  /// intermediate the deck is playing from.
  enum FlipState: Equatable { case off, rendering, on(URL) }
  @Published private(set) var flipState: FlipState = .off
  private var flipTask: Task<Void, Never>?
  /// Background pre-render of the CURRENT track's flip, started when the track
  /// becomes current — pressing Flip must flip this song, not finish two
  /// minutes into the next one.
  private var flipWarm: (key: String, recipe: VocalFlipRecipe, task: Task<URL, Error>)?

  let engine = EnginePlayer()
  private let library: Library
  private let flipper: VocalFlipper
  private let discord = DiscordPresence()
  private var defaultsObserver: NSObjectProtocol?
  // bumped on every new selection so a slow in-flight pull can't clobber a newer choice
  private var generation = 0
  private var workTask: Task<Void, Never>?

  // Apple Music live-sync + prefetch state
  /// Music's queue pointer (= the prefetched next track while we drive the queue). Used
  /// to dedup our own queue mutations from genuine external changes.
  private var lastMusicIdentity: String?
  /// What plunk is actually playing right now (≠ lastMusicIdentity when we've driven
  /// Music's pointer ahead to prefetch).
  private var playingIdentity: String?
  /// True when the current track came from Apple Music (so we may drive its queue);
  /// false for search / recents, where Music's queue is unrelated and must not be moved.
  private var currentFromAppleMusic = false
  /// The generation we last advanced+prefetched for (advance Music at most once/track).
  private var prefetchedForGen: Int?
  /// Ignore playerInfo echoes from plunk's own Music mutations until this time.
  private var suppressUntil = Date.distantPast

  /// Music's pointer is parked one ahead of what we're playing (we drove it to prefetch).
  private var pointerAhead: Bool {
    guard let last = lastMusicIdentity, let playing = playingIdentity else { return false }
    return last != playing
  }
  private var syncDebounce: Task<Void, Never>?
  private var musicObservers: [NSObjectProtocol] = []

  private struct Prefetch {
    let query: String
    /// The Apple Music identity that seeded this prefetch (for dedup after consume).
    let musicIdentity: String
    /// Bumped per prefetch so a superseded background pull can't clobber `upNext`.
    let gen: Int
    let task: Task<TrackInfo, Error>
  }
  private var prefetch: Prefetch?
  private var prefetchGen = 0
  /// The ready-to-play prefetched track armed for an automix transition.
  private var armedPrefetch: (info: TrackInfo, musicIdentity: String)?

  init() {
    let missing = Tools.missing()
    setupError =
      missing.isEmpty
      ? nil
      : "missing tools: \(missing.joined(separator: ", ")) — install with `brew install yt-dlp ffmpeg deno`"
    let cookies = ProcessInfo.processInfo.environment["YTDLP_COOKIES"]
    let cache = Cache()
    library = Library(cache: cache, ytdlp: YtDlp(cookiesPath: cookies))
    flipper = VocalFlipper(cache: cache)
    recent = cache.loadRecent()

    // apply persisted defaults from the Settings window
    format = defaultFormat
    preset = defaultPreset
    if let p = defaultPreset.params { params = p }

    // walk the Apple Music queue when a track finishes (if enabled)
    engine.onNaturalFinish = { [weak self] in self?.advanceQueue() }
    // media keys / Control Center next & previous drive the Apple Music queue
    engine.onNext = { [weak self] in self?.next() }
    engine.onPrevious = { [weak self] in self?.previous() }

    // mirror now-playing out to Discord Rich Presence
    engine.onNowPlaying = { [weak self] in self?.pushDiscord() }
    engine.onNowPlayingCleared = { [weak self] in self?.discord.clear() }
    discord.setEnabled(discordEnabled)

    // beatmatched automix: the engine hands off to the prefetched track itself
    engine.automixEnabled = automixEnabled
    engine.onAutomixHandoff = { [weak self] track in self?.handleAutomixHandoff(track) }
    // react when the Discord toggle (or any default) changes in Settings
    defaultsObserver = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.reconcileDiscord() }
    }

    // live-sync: Music broadcasts this on every play/pause/track change (no permission needed)
    let dnc = DistributedNotificationCenter.default()
    for name in ["com.apple.Music.playerInfo", "com.apple.iTunes.playerInfo"] {
      let token = dnc.addObserver(
        forName: Notification.Name(name), object: nil, queue: .main
      ) { [weak self] note in
        // delivered on .main, so assume main-actor isolation
        MainActor.assumeIsolated { self?.handleMusicNotification(note.userInfo ?? [:]) }
      }
      musicObservers.append(token)
    }
  }

  deinit {
    let dnc = DistributedNotificationCenter.default()
    musicObservers.forEach { dnc.removeObserver($0) }
    if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    syncDebounce?.cancel()
    prefetch?.task.cancel()
  }

  var idle: Bool { busy == nil && meta == nil }

  /// Menu-bar glyph reflecting live state.
  var menuBarSymbol: String {
    if outOfSync { return "exclamationmark.triangle.fill" }
    if busy != nil { return "arrow.down.circle" }
    if track != nil { return "waveform" }
    return "music.note"
  }

  // MARK: settings-backed defaults

  var defaultPreset: Preset {
    UserDefaults.standard.string(forKey: PrefKey.preset).flatMap(Preset.init) ?? .nightcore
  }

  var defaultFormat: ExportFormat {
    UserDefaults.standard.string(forKey: PrefKey.format).flatMap(ExportFormat.init) ?? .mp3
  }

  var autoGrabOnOpen: Bool { UserDefaults.standard.bool(forKey: PrefKey.autoGrab) }

  var followQueue: Bool { UserDefaults.standard.bool(forKey: PrefKey.followQueue) }

  /// Defaults to on (the feature the user asked for) until explicitly turned off.
  var discordEnabled: Bool {
    UserDefaults.standard.object(forKey: PrefKey.discordPresence) == nil
      ? true : UserDefaults.standard.bool(forKey: PrefKey.discordPresence)
  }

  var automixEnabled: Bool {
    UserDefaults.standard.object(forKey: PrefKey.automix) == nil
      ? true : UserDefaults.standard.bool(forKey: PrefKey.automix)
  }

  /// The vocal-flip recipe from Settings (falls back to the tuned standard).
  var flipRecipe: VocalFlipRecipe {
    let d = UserDefaults.standard
    var r = VocalFlipRecipe.standard
    if let raw = d.string(forKey: PrefKey.flipEngine),
      let engine = VocalFlipRecipe.Engine(rawValue: raw)
    { r.engine = engine }
    if d.object(forKey: PrefKey.flipPitch) != nil {
      r.pitchSemitones = d.double(forKey: PrefKey.flipPitch)
    }
    if d.object(forKey: PrefKey.flipFormant) != nil {
      r.formantRatio = d.double(forKey: PrefKey.flipFormant)
    }
    r.polish = d.bool(forKey: PrefKey.flipPolish)
    r.grit = d.bool(forKey: PrefKey.flipGrit)
    return r
  }

  /// Human label for what's playing right now (for the read-only deck readout).
  var currentVibe: String {
    vibeLabel(params) + (params.bitcrush ? " + bitcrush" : "")
      + (params.vocalFlip ? " + vocal flip" : "")
  }

  // MARK: vocal flip

  /// The deck-toggle action: flip on/off for the current track.
  func toggleFlip() {
    if params.vocalFlip {
      update { $0.vocalFlip = false }
      deactivateFlip()
      return
    }
    guard let track, !engine.mixing else { return }
    guard FlipTools.availableEngines().contains(flipRecipe.engine) else {
      errorMessage = "vocal flip: \(FlipTools.installHint(flipRecipe.engine))"
      return
    }
    update { $0.vocalFlip = true }
    startFlipRender(for: track)
  }

  /// Pre-render `track`'s flip in the background. Cancels the previous track's
  /// warm render; the result is the same cached intermediate `startFlipRender`
  /// consumes, so the Flip button swaps in seconds instead of minutes.
  private func warmFlip(for track: TrackInfo) {
    flipWarm?.task.cancel()
    flipWarm = nil
    let recipe = flipRecipe
    guard FlipTools.availableEngines().contains(recipe.engine) else { return }
    let flipper = flipper
    let task = Task.detached(priority: .utility) {
      try await flipper.flippedFile(for: track, recipe: recipe)
    }
    flipWarm = (track.meta.key, recipe, task)
  }

  /// Render (or fetch the cached / in-flight warm) flipped intermediate
  /// off-main, then swap the live deck onto it. Generation-guarded like every
  /// other async pipeline here.
  private func startFlipRender(for track: TrackInfo) {
    flipTask?.cancel()
    flipState = .rendering
    let gen = generation
    let recipe = flipRecipe
    let warm =
      flipWarm?.key == track.meta.key && flipWarm?.recipe == recipe ? flipWarm?.task : nil
    flipTask = Task { @MainActor [weak self, flipper] in
      do {
        let url: URL
        if let warm {
          url = try await warm.value
        } else {
          url = try await flipper.flippedFile(for: track, recipe: recipe)
        }
        guard let self, !Task.isCancelled, gen == self.generation, self.params.vocalFlip
        else { return }
        self.engine.swapCurrentSource(url: url)
        self.flipState = .on(url)
      } catch is CancellationError {
        // superseded — whoever cancelled owns flipState
      } catch {
        guard let self, gen == self.generation else { return }
        self.flipState = .off
        self.params.vocalFlip = false
        self.errorMessage = self.message(for: error)
      }
    }
  }

  /// Turn the flip off: cancel any render and put the plain file back on the deck.
  private func deactivateFlip() {
    flipTask?.cancel()
    flipTask = nil
    if case .on = flipState, let track {
      engine.swapCurrentSource(url: URL(fileURLWithPath: track.playablePath))
    }
    flipState = .off
  }

  /// After a track becomes current: drop stale flip state, and when the flip
  /// intent carried over (queue advance / automix with keepEffect), start the
  /// new track's flip render.
  private func reconcileFlip(for track: TrackInfo) {
    flipTask?.cancel()
    flipTask = nil
    flipState = .off
    guard params.vocalFlip else { return }
    guard FlipTools.availableEngines().contains(flipRecipe.engine) else {
      params.vocalFlip = false
      return
    }
    startFlipRender(for: track)
  }

  // MARK: Discord Rich Presence

  /// Mirror the current track + remix vibe + playback position out to Discord.
  private func pushDiscord() {
    guard discordEnabled, let meta, track != nil else {
      discord.clear()
      return
    }
    let vibe = currentVibe
    discord.update(
      .init(
        title: songTitle(meta.title, artist: meta.artist), artist: meta.artist, vibe: vibe,
        artURL: meta.thumbnail, isPlaying: engine.isPlaying,
        elapsed: engine.progress * engine.effectiveDuration, duration: engine.effectiveDuration))
  }

  /// Strip a leading "Artist - " and trailing "(Official Video)"-style noise from a
  /// YouTube title so the Discord card shows just the song (Spotify-style).
  private func songTitle(_ title: String, artist: String) -> String {
    var t = title
    if !artist.isEmpty {
      for sep in [" - ", " — ", " – ", ": "] {
        let prefix = artist + sep
        if t.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil {
          t.removeFirst(prefix.count)
          break
        }
      }
    }
    t = t.replacingOccurrences(
      of: #"\s*[\(\[][^\)\]]*[\)\]]\s*$"#, with: "", options: .regularExpression)
    let trimmed = t.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? title : trimmed
  }

  private func reconcileDiscord() {
    discord.setEnabled(discordEnabled)
    if discordEnabled { pushDiscord() }
    engine.automixEnabled = automixEnabled
  }

  // MARK: automix

  /// The engine finished a beatmatched crossfade into the prefetched track — sync the
  /// model to the new now-playing track and warm/arm the one after it.
  private func handleAutomixHandoff(_ track: TrackInfo) {
    generation += 1
    workTask?.cancel()
    // Music's pointer is already parked on this track (we drove it there to prefetch)
    let id =
      (armedPrefetch?.info.meta.key == track.meta.key ? armedPrefetch?.musicIdentity : nil)
      ?? identity(track.meta.title, track.meta.artist)
    playingIdentity = id
    lastMusicIdentity = id
    currentFromAppleMusic = true
    outOfSync = false
    errorMessage = nil
    meta = track.meta
    self.track = track
    recent = library.cache.loadRecent()
    warmFlip(for: track)
    reconcileFlip(for: track)
    clearPrefetch()  // also disarms the engine
    prefetchNext()  // advance Music to the next track + prefetch + arm
  }

  // MARK: Apple Music

  /// Read the currently-selected Apple Music track and remix it with the default preset.
  func grabFromAppleMusic() {
    do {
      let track = try AppleMusic.currentTrack()
      suppressEchoes()
      AppleMusic.pausePlayback()  // plunk is the player now — avoid double audio
      remix(track)
    } catch {
      errorMessage = message(for: error)
    }
  }

  /// Used by the menu-bar panel's "auto-grab on open" setting.
  func grabIfIdle() {
    guard idle else { return }
    grabFromAppleMusic()
  }

  /// When a track finishes and "follow queue" is on, advance the queue.
  private func advanceQueue() {
    guard followQueue else { return }
    next()
  }

  /// Manual skip forward — uses the prefetched track for an instant swap if ready.
  func next() {
    guard let pf = prefetch else {
      advanceManually()
      return
    }
    // consume synchronously so a re-entrant next() (double-tap/media key) can't grab
    // the same in-flight task and double-advance Music
    prefetch = nil
    upNext = nil
    upNextReady = false
    let gen = generation
    Task { @MainActor in
      do {
        let info = try await pf.task.value
        guard gen == generation else { return }  // user moved on during the pull — don't hijack
        consumePrefetch(info, musicIdentity: pf.musicIdentity)
        prefetchNext()  // advance Music to the following track + prefetch it
      } catch {
        guard gen == generation else { return }
        advanceManually()  // prefetch failed — remix the intended next track live
      }
    }
  }

  /// Skip forward without a ready prefetch. If we've already driven Music's pointer onto
  /// the next track, remix that in place; otherwise advance the queue a step.
  private func advanceManually() {
    if pointerAhead {
      step { try AppleMusic.currentTrack() }
    } else {
      step { try AppleMusic.advanceToNext() }
    }
  }

  /// Manual skip back. With the pointer parked one ahead, the first step-back lands on
  /// the current track and the second on the genuine previous.
  func previous() {
    suppressEchoes()
    do {
      if pointerAhead { _ = try AppleMusic.goToPrevious() }
      let track = try AppleMusic.goToPrevious()
      remix(track, keepEffect: true)
    } catch AppleMusicError.nothingPlaying {
      errorMessage = "Reached the start of the Apple Music queue."
    } catch {
      errorMessage = message(for: error)
    }
  }

  private func step(_ read: () throws -> AppleMusic.Track) {
    suppressEchoes()
    do {
      remix(try read(), keepEffect: true)
    } catch AppleMusicError.nothingPlaying {
      errorMessage = "Reached the end of the Apple Music queue."
    } catch {
      errorMessage = message(for: error)
    }
  }

  /// `keepEffect`: carry the current remix over (queue advances / live-sync) rather
  /// than resetting to the default preset (a fresh manual grab). Called when Music's
  /// pointer is already on `track`, so playing == pointer (not yet driven ahead).
  private func remix(_ track: AppleMusic.Track, keepEffect: Bool = false) {
    let id = identity(track.title, track.artist)
    playingIdentity = id
    lastMusicIdentity = id
    currentFromAppleMusic = true
    outOfSync = false
    query = track.artist.isEmpty ? track.title : "\(track.artist) \(track.title)"
    if !keepEffect { applyPreset(defaultPreset) }
    startRemix(query: query, artist: track.artist, duration: track.duration, autoPlay: true)
  }

  // MARK: live-sync (DistributedNotificationCenter)

  private func identity(_ title: String, _ artist: String) -> String {
    "\(title)\t\(artist)".lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Briefly ignore the playerInfo echoes caused by plunk's own Music mutations.
  private func suppressEchoes() { suppressUntil = Date().addingTimeInterval(1.5) }

  private func handleMusicNotification(_ userInfo: [AnyHashable: Any]) {
    guard let name = userInfo["Name"] as? String, !name.isEmpty else { return }
    let artist = userInfo["Artist"] as? String ?? ""
    let id = identity(name, artist)

    if Date() < suppressUntil {  // our own pause/skip echoing back
      lastMusicIdentity = id
      return
    }
    if id == lastMusicIdentity { return }  // same track — just a play/pause toggle
    lastMusicIdentity = id

    // a genuine external change in Apple Music
    guard followQueue else {
      outOfSync = true  // surface a re-sync affordance; don't auto-hijack
      return
    }
    let durationMs = userInfo["Total Time"] as? Int
    let track: AppleMusic.Track = (name, artist, durationMs.map { Double($0) / 1000 })
    syncDebounce?.cancel()
    syncDebounce = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 250_000_000)  // coalesce Music's burst
      if Task.isCancelled { return }
      self.suppressEchoes()
      AppleMusic.pausePlayback()
      self.remix(track, keepEffect: true)
    }
  }

  // MARK: prefetch

  /// Drive Music's real queue one step ahead (silent — Music is paused) to read the
  /// next track, then resolve + pull it so Next / auto-advance is instant. Only runs
  /// for Apple-Music-sourced playback while "keep playing through the queue" is on, so
  /// we never move the queue out from under a search/recents session.
  private func prefetchNext() {
    guard followQueue, currentFromAppleMusic else {
      clearPrefetch()
      return
    }
    guard prefetchedForGen != generation, !pointerAhead else { return }  // advance once/track
    prefetchedForGen = generation
    suppressEchoes()
    guard let next = try? AppleMusic.advanceToNext() else {
      clearPrefetch()
      return
    }
    let nextId = identity(next.title, next.artist)
    guard nextId != playingIdentity else {  // advancing didn't move = end of the queue
      clearPrefetch()
      return
    }
    lastMusicIdentity = nextId  // Music's pointer now sits on the prefetched track

    let q = next.artist.isEmpty ? next.title : "\(next.artist) \(next.title)"
    prefetch?.task.cancel()
    prefetchGen += 1
    let gen = prefetchGen
    upNext = TrackMeta(
      key: "", title: next.title, artist: next.artist, duration: next.duration ?? 0,
      thumbnail: nil, webpageURL: "", source: "")
    upNextReady = false
    let lib = library
    let artist = next.artist
    let duration = next.duration
    let task = Task.detached(priority: .utility) { [flipper] () throws -> TrackInfo in
      let meta = try await lib.resolve(q, artist: artist, expectedDuration: duration)
      let info = try await lib.pull(meta)
      await MainActor.run { [weak self] in
        guard let self, self.prefetchGen == gen else { return }  // superseded — don't clobber
        self.upNext = info.meta
        self.upNextReady = true
        self.armedPrefetch = (info, nextId)
        // arm a beatmatched transition into it (engine triggers ~8 bars before the end)
        if self.automixEnabled { self.engine.armAutomix(info, params: self.params) }
      }
      // pre-render the next track's flip for the handoff, fire-and-forget —
      // next() awaits this task's value for instant skips, so the warm must
      // never delay it
      Task.detached(priority: .utility) { [weak self] in
        let (flipOn, recipe) = await MainActor.run { [weak self] in
          guard let self else { return (false, VocalFlipRecipe.standard) }
          return (self.params.vocalFlip, self.flipRecipe)
        }
        if flipOn { _ = try? await flipper.flippedFile(for: info, recipe: recipe) }
      }
      return info
    }
    prefetch = Prefetch(query: q, musicIdentity: nextId, gen: gen, task: task)
  }

  /// Instant swap to an already-pulled prefetch (mirrors remix()'s state setup).
  private func consumePrefetch(_ info: TrackInfo, musicIdentity: String) {
    generation += 1
    workTask?.cancel()
    engine.stop()
    clearPrefetch()
    errorMessage = nil
    // carry the current remix over; Music's pointer is already parked on this track
    playingIdentity = musicIdentity
    lastMusicIdentity = musicIdentity
    currentFromAppleMusic = true
    outOfSync = false
    meta = info.meta
    track = info
    recent = library.cache.loadRecent()
    engine.load(info)
    engine.apply(params)
    engine.play()
    warmFlip(for: info)
    reconcileFlip(for: info)
    busy = nil
  }

  private func clearPrefetch() {
    prefetchGen += 1  // supersede any in-flight prefetch write
    prefetch?.task.cancel()
    prefetch = nil
    upNext = nil
    upNextReady = false
    armedPrefetch = nil
    engine.disarmAutomix()
  }

  // MARK: load

  /// Search-bar submit: load but don't auto-play (avoid surprise playback). A search
  /// isn't from Apple Music, so we must not drive its queue.
  func submit() {
    currentFromAppleMusic = false
    playingIdentity = nil
    startRemix(query: query, artist: nil, duration: nil, autoPlay: false)
  }

  private func startRemix(query rawQuery: String, artist: String?, duration: Double?, autoPlay: Bool)
  {
    let q = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return }
    generation += 1
    let gen = generation
    workTask?.cancel()
    clearPrefetch()
    engine.stop()
    meta = nil
    track = nil
    errorMessage = nil
    busy = .resolving

    workTask = Task { [library] in
      do {
        let resolved = try await library.resolve(q, artist: artist, expectedDuration: duration)
        if gen != generation { return }
        meta = resolved
        busy = .pulling
        let pulled = try await library.pull(resolved)
        if gen != generation { return }
        track = pulled
        meta = pulled.meta
        recent = library.cache.loadRecent()
        engine.load(pulled)
        engine.apply(params)
        if autoPlay { engine.play() }
        warmFlip(for: pulled)
        reconcileFlip(for: pulled)
        busy = nil
        prefetchNext()  // warm the next queue track
      } catch is CancellationError {
        // superseded by a newer request
      } catch {
        if gen != generation { return }
        errorMessage = message(for: error)
        meta = nil
        busy = nil
      }
    }
  }

  func pickRecent(_ track: TrackInfo) {
    generation += 1
    workTask?.cancel()
    clearPrefetch()
    engine.stop()
    busy = nil
    errorMessage = nil
    // a recents pick isn't tied to Apple Music's queue — don't drive it
    currentFromAppleMusic = false
    playingIdentity = identity(track.meta.title, track.meta.artist)
    lastMusicIdentity = playingIdentity
    outOfSync = false
    self.meta = track.meta
    self.track = track
    engine.load(track)
    engine.apply(params)
    warmFlip(for: track)
    reconcileFlip(for: track)
  }

  func reset() {
    generation += 1
    workTask?.cancel()
    flipTask?.cancel()
    flipTask = nil
    flipWarm?.task.cancel()
    flipWarm = nil
    flipState = .off
    clearPrefetch()
    engine.stop()
    busy = nil
    meta = nil
    track = nil
    errorMessage = nil
    query = ""
    playingIdentity = nil
    currentFromAppleMusic = false
  }

  // MARK: params

  /// Mutate params, mark the preset custom, and push the change to the live engine.
  func update(_ transform: (inout RemixParams) -> Void) {
    var next = params
    transform(&next)
    params = next
    preset = .custom
    engine.apply(next)
  }

  func applyPreset(_ preset: Preset) {
    self.preset = preset
    if let p = preset.params {
      // presets replace params wholesale, silently clearing vocalFlip — swap the
      // deck back to the plain file first or the audio and button would desync
      if params.vocalFlip { deactivateFlip() }
      params = p
      engine.apply(p)
      // the chosen preset also becomes the default for the next grab
      UserDefaults.standard.set(preset.rawValue, forKey: PrefKey.preset)
    }
  }

  // MARK: export

  func export() {
    guard let track else { return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "\(suggestedName(track)).\(format.ext)"
    panel.canCreateDirectories = true
    panel.title = "export remix"
    panel.begin { [weak self] response in
      guard response == .OK, let url = panel.url, let self else { return }
      self.runExport(to: url)
    }
  }

  private func runExport(to url: URL) {
    guard let track else { return }
    exporting = true
    let params = params
    let format = format
    let recipe = flipRecipe
    Task { [library, flipper] in
      do {
        // flip on → render from the flipped intermediate (cache hit if the live
        // preview already rendered it)
        var source: String?
        if params.vocalFlip {
          source = try await flipper.flippedFile(for: track, recipe: recipe).path
        }
        try await library.ffmpeg.render(
          track: track, params: params, format: format,
          scratchDir: library.cache.rendersDir, to: url, sourceOverride: source)
        exporting = false
        NSWorkspace.shared.activateFileViewerSelecting([url])
      } catch {
        exporting = false
        errorMessage = message(for: error)
      }
    }
  }

  private func suggestedName(_ track: TrackInfo) -> String {
    // YouTube titles often already lead with the artist — avoid "Artist - Artist - Title"
    let title = track.meta.title
    let artist = track.meta.artist
    let base =
      title.lowercased().contains(artist.lowercased()) ? title : "\(artist) - \(title)"
    let name = "\(base) (\(vibeLabel(params))\(params.vocalFlip ? " + vocal flip" : ""))"
    return String(name.map { "/:".contains($0) ? "-" : $0 })
  }

  private func message(for error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
  }
}
