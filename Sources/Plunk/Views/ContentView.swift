import PlunkKit
import SwiftUI

/// Shared native card surface: an opaque control-background panel with a hairline
/// separator border (HIG: don't stack materials — the popover already supplies one).
extension View {
  func plunkCard(padding: CGFloat = 14) -> some View {
    self
      .padding(padding)
      .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
      .overlay(
        RoundedRectangle(cornerRadius: 10)
          .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
  }
}

/// The menu-bar panel — a minimal nightcore-DJ surface: grab what's playing in Apple
/// Music (the primary action) and watch the read-only deck. Search is tucked behind a
/// header icon; the fine controls live in Settings.
struct ContentView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.openSettings) private var openSettings
  @State private var searching = false

  var body: some View {
    VStack(spacing: 0) {
      header

      VStack(spacing: 14) {
        if searching {
          SearchBar(text: $model.query, busy: model.busy != nil) {
            model.submit()
            searching = false
          }
        }

        if let setupError = model.setupError { banner(setupError, .orange) }
        if let error = model.errorMessage { banner(error, .red) }
        if model.busy == .resolving { ResolveSkeleton() }

        if let meta = model.meta, model.busy != .resolving {
          if model.track != nil, model.busy == nil {
            MixingBanner(engine: model.engine)
            DJDeck(
              meta: meta, baseBPM: model.track?.beat?.bpm, vibe: model.currentVibe,
              engine: model.engine)
          } else {
            TrackCard(meta: meta, pulling: model.busy == .pulling) { EmptyView() }
          }
        } else if model.idle, !searching {
          emptyState
        }
      }
      .padding(16)

      Divider()
      footer
    }
    .frame(width: 340)
    .task {
      if model.autoGrabOnOpen { model.grabIfIdle() }
    }
  }

  // MARK: header

  private var header: some View {
    HStack(spacing: 12) {
      (Text("Bitcrush").fontWeight(.semibold) + Text("<3").foregroundStyle(.pink))
        .font(.system(.body, design: .rounded))
      Spacer()
      if model.outOfSync {
        Button(action: model.grabFromAppleMusic) {
          Label("Re-sync", systemImage: "arrow.triangle.2.circlepath")
        }
        .controlSize(.small).font(.caption)
        .help("Apple Music moved on — click to catch up")
      }
      Button(action: model.grabFromAppleMusic) {
        Image(systemName: "music.note.list")
      }
      .help("Grab what's playing in Apple Music")
      Button { withAnimation(.snappy) { searching.toggle() } } label: {
        Image(systemName: "magnifyingglass")
      }
      .help("Search for a song")
    }
    .buttonStyle(.borderless)
    .padding(.horizontal, 16)
    .padding(.top, 14)
    .padding(.bottom, 10)
  }

  // MARK: idle empty state

  private var emptyState: some View {
    VStack(spacing: 10) {
      Button(action: model.grabFromAppleMusic) {
        Label("Grab from Apple Music", systemImage: "music.note.list")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .help("Remix whatever is playing in Apple Music")

      Text("or tap 􀊫 to search").font(.caption2).foregroundStyle(.tertiary)
    }
    .padding(.vertical, 8)
  }

  // MARK: footer

  private var footer: some View {
    HStack {
      Button("Settings…") {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
      }
      Spacer()
      Button("Quit") { NSApplication.shared.terminate(nil) }
    }
    .buttonStyle(.borderless)
    .font(.callout)
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  private func banner(_ text: String, _ tone: Color) -> some View {
    Label(text, systemImage: "exclamationmark.triangle.fill")
      .font(.caption)
      .foregroundStyle(tone)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(10)
      .background(tone.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
  }
}
