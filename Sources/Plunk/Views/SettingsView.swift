import PlunkKit
import SwiftUI

struct SettingsView: View {
  @AppStorage(PrefKey.format) private var defaultFormat = ExportFormat.mp3.rawValue
  @AppStorage(PrefKey.autoGrab) private var autoGrabOnOpen = false
  @AppStorage(PrefKey.followQueue) private var followQueue = false
  @AppStorage(PrefKey.discordPresence) private var discordPresence = true
  @AppStorage(PrefKey.automix) private var automix = true
  @AppStorage(PrefKey.flipEngine) private var flipEngine = VocalFlipRecipe.Engine.rubberband.rawValue
  @AppStorage(PrefKey.flipPitch) private var flipPitch = VocalFlipRecipe.standard.pitchSemitones
  @AppStorage(PrefKey.flipFormant) private var flipFormant = VocalFlipRecipe.standard.formantRatio
  @AppStorage(PrefKey.flipPolish) private var flipPolish = false
  @AppStorage(PrefKey.flipGrit) private var flipGrit = VocalFlipRecipe.standard.grit

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

      Section("Vocal flip (experimental)") {
        let engines = FlipTools.availableEngines()
        if engines.isEmpty {
          Text("Makes vocals read feminine (pitch and formants shifted independently). Install it with `brew install rubberband`.")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          if engines.count > 1 {
            Picker("Engine", selection: $flipEngine) {
              ForEach(engines) { Text($0.label).tag($0.rawValue) }
            }
          }
          HStack {
            Stepper(value: $flipPitch, in: 1...9, step: 0.5) {
              Text("Pitch  +\(flipPitch, specifier: "%.1f") st")
            }
          }
          HStack {
            Text("Formants  ×\(flipFormant, specifier: "%.2f")")
            Slider(value: $flipFormant, in: 1.05...1.35, step: 0.01)
          }
          Toggle("Grit (rasp exciter)", isOn: $flipGrit)
          Toggle("Chorus + echo polish (Porter-style sheen)", isOn: $flipPolish)
          Text("Each track's flip renders in the background when it loads, so the button usually swaps right away. Changes here apply to the next render.")
            .font(.caption)
            .foregroundStyle(.secondary)
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
