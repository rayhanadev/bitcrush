import PlunkKit
import SwiftUI

struct SettingsView: View {
  @AppStorage(PrefKey.format) private var defaultFormat = ExportFormat.mp3.rawValue
  @AppStorage(PrefKey.autoGrab) private var autoGrabOnOpen = false
  @AppStorage(PrefKey.followQueue) private var followQueue = false
  @AppStorage(PrefKey.discordPresence) private var discordPresence = true
  @AppStorage(PrefKey.automix) private var automix = true

  var body: some View {
    Form {
      Section("Sound") {
        PresetSegments()
        DeckKnobs()
          .padding(.vertical, 4)
        Text("Applied to every track.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("Export") {
        Picker("Format", selection: $defaultFormat) {
          ForEach(ExportFormat.allCases) { format in
            Text(format.label).tag(format.rawValue)
          }
        }
      }

      Section("Apple Music") {
        Toggle("Grab the current song when I open Bitcrush<3", isOn: $autoGrabOnOpen)
        Toggle("Keep playing through the queue", isOn: $followQueue)
        Toggle("Beatmatched automix transitions", isOn: $automix)
          .disabled(!followQueue)
        Text("Re-sources what's playing in Music from YouTube (needs Automation permission). Keep playing auto-advances the queue; automix beatmatches between tracks.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("Discord") {
        Toggle("Show what I'm playing on Discord", isOn: $discordPresence)
        Text("Shows the track and vibe on your Discord profile. Just needs the Discord app running.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .frame(width: 420, height: 580)
  }
}
