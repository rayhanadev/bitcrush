import Testing

@testable import PlunkKit

@Suite("official-audio scoring")
struct SearchScoringTests {
  // mirrors a real `ytsearch` for "Daft Punk Giorgio by Moroder"
  let official = TrackCandidate(
    title: "Daft Punk - Giorgio by Moroder (Official Audio)", channel: "Daft Punk",
    durationSeconds: 554)
  let live = TrackCandidate(
    title: "Giorgio Moroder / Daft Punk - Giorgio by Moroder - live", channel: "Rudolf Chmelar",
    durationSeconds: 554)
  let reupload = TrackCandidate(
    title: "Daft Punk - Giorgio by Moroder (High Quality)", channel: "Red System Of U Day",
    durationSeconds: 546)
  let wrong = TrackCandidate(title: "Family Guy - Daft Punk", channel: "Mr. Rupert", durationSeconds: 59)

  func best(_ candidates: [TrackCandidate], artist: String?, duration: Double?, query: String)
    -> TrackCandidate
  {
    candidates.max {
      officialScore(for: $0, artist: artist, expectedDuration: duration, query: query)
        < officialScore(for: $1, artist: artist, expectedDuration: duration, query: query)
    }!
  }

  @Test("picks the official artist audio over live / reupload / wrong results")
  func picksOfficial() {
    let chosen = best(
      [live, reupload, official, wrong], artist: "Daft Punk", duration: 547,
      query: "Daft Punk Giorgio by Moroder")
    #expect(chosen.title.contains("Official Audio"))
  }

  @Test("penalizes a live version")
  func livePenalized() {
    let q = "Daft Punk Giorgio by Moroder"
    #expect(
      officialScore(for: official, artist: "Daft Punk", expectedDuration: 547, query: q)
        > officialScore(for: live, artist: "Daft Punk", expectedDuration: 547, query: q))
  }

  @Test("a '- Topic' channel scores as official")
  func topicChannel() {
    let topic = TrackCandidate(
      title: "Giorgio by Moroder", channel: "Daft Punk - Topic", durationSeconds: 547)
    #expect(officialScore(for: topic, artist: "Daft Punk", expectedDuration: 547, query: "x") > 60)
  }

  @Test("duration mismatch is penalized even for a plausible title")
  func durationMismatch() {
    let q = "Daft Punk Giorgio by Moroder"
    let onTime = officialScore(for: official, artist: "Daft Punk", expectedDuration: 554, query: q)
    let wrongLen = TrackCandidate(
      title: "Daft Punk - Giorgio by Moroder (Official Audio)", channel: "Daft Punk",
      durationSeconds: 120)
    let offTime = officialScore(for: wrongLen, artist: "Daft Punk", expectedDuration: 554, query: q)
    #expect(onTime > offTime)
  }

  @Test("if the query asks for a remix, the remix isn't penalized")
  func remixWhenRequested() {
    let remix = TrackCandidate(
      title: "Song (Official Remix)", channel: "Artist", durationSeconds: 200)
    let q = "Artist Song Remix"
    #expect(officialScore(for: remix, artist: "Artist", expectedDuration: 200, query: q) > 50)
  }
}
