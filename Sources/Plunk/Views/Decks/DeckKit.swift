import PlunkKit
import SwiftUI

// MARK: - model bindings shared by every deck

extension AppModel {
  /// Live binding to a `Double` remix param (drives `update`, marks preset custom).
  func paramBinding(_ keyPath: WritableKeyPath<RemixParams, Double>) -> Binding<Double> {
    Binding(get: { self.params[keyPath: keyPath] }, set: { v in self.update { $0[keyPath: keyPath] = v } })
  }
  var pitchBinding: Binding<Double> {
    Binding(get: { Double(self.params.pitch) }, set: { v in self.update { $0.pitch = Int(v.rounded()) } })
  }
  var linkedBinding: Binding<Bool> {
    Binding(get: { self.params.linked }, set: { v in self.update { $0.linked = v } })
  }
  var bitcrushBinding: Binding<Bool> {
    Binding(get: { self.params.bitcrush }, set: { v in self.update { $0.bitcrush = v } })
  }
  var presetBinding: Binding<Preset> {
    Binding(get: { self.preset }, set: { self.applyPreset($0) })
  }
}

// MARK: - rotary knob (the "more than sliders" control)

/// A draggable rotary knob: drag up to raise, down to lower (270° sweep, gap at the
/// bottom). Bound to a remix param; shows its label and current value beneath.
struct Knob: View {
  let title: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  var step: Double = 0.01
  var display: String
  var tint: Color = .accentColor
  var size: CGFloat = 42

  @State private var dragStart: Double?

  private var fraction: Double {
    let span = range.upperBound - range.lowerBound
    guard span > 0 else { return 0 }
    return min(max((value - range.lowerBound) / span, 0), 1)
  }

  var body: some View {
    VStack(spacing: 5) {
      ZStack {
        // unlit track: a 270° arc with the gap at the bottom
        Circle()
          .trim(from: 0, to: 0.75)
          .stroke(Color.primary.opacity(0.15), style: .init(lineWidth: 3, lineCap: .round))
          .rotationEffect(.degrees(135))
        // lit portion up to the current value
        Circle()
          .trim(from: 0, to: 0.75 * fraction)
          .stroke(tint, style: .init(lineWidth: 3, lineCap: .round))
          .rotationEffect(.degrees(135))
        // knurled body
        Circle()
          .fill(
            LinearGradient(
              colors: [Color(white: 0.34), Color(white: 0.16)], startPoint: .top,
              endPoint: .bottom)
          )
          .overlay(Circle().strokeBorder(.black.opacity(0.5), lineWidth: 0.5))
          .padding(7)
          .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
        // pointer
        Capsule()
          .fill(tint)
          .frame(width: 2.5, height: size * 0.20)
          .offset(y: -size * 0.22)
          .rotationEffect(.degrees(-135 + 270 * fraction))
      }
      .frame(width: size, height: size)
      .contentShape(Circle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { g in
            let start = dragStart ?? value
            if dragStart == nil { dragStart = start }
            let span = range.upperBound - range.lowerBound
            let delta = -Double(g.translation.height) / 130 * span  // 130pt ≈ full sweep
            let raw = start + delta
            let snapped = (raw / step).rounded() * step
            value = min(max(snapped, range.lowerBound), range.upperBound)
          }
          .onEnded { _ in dragStart = nil }
      )

      Text(title)
        .font(.system(size: 9, weight: .semibold)).textCase(.uppercase)
        .foregroundStyle(.secondary).kerning(0.5)
      Text(display)
        .font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
    }
  }
}

// MARK: - spinner

/// Rotates its content continuously while `spinning`, frozen otherwise. Driven by a
/// paused-aware `TimelineView` so it costs nothing when playback is stopped.
struct Spinner<Content: View>: View {
  var spinning: Bool
  var period: Double
  @ViewBuilder var content: Content

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !spinning)) { ctx in
      let secs = ctx.date.timeIntervalSinceReferenceDate
      let angle = secs.truncatingRemainder(dividingBy: period) / period * 360
      content.rotationEffect(.degrees(angle))
    }
  }
}

// MARK: - shared control rows

/// prev · play/pause · next — tinted to match the surrounding deck.
struct TransportRow: View {
  @ObservedObject var engine: EnginePlayer
  @EnvironmentObject var model: AppModel
  var tint: Color = .accentColor
  var spacing: CGFloat = 22
  var compact = false

  var body: some View {
    HStack(spacing: spacing) {
      Button(action: model.previous) { Image(systemName: "backward.end.fill") }
        .accessibilityLabel("previous")
      Button(action: engine.togglePlay) {
        Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
          .imageScale(compact ? .medium : .large)
      }
      .disabled(!engine.ready)
      .accessibilityLabel(engine.isPlaying ? "pause" : "play")
      Button(action: model.next) { Image(systemName: "forward.end.fill") }
        .accessibilityLabel("next")
    }
    .font(.system(size: compact ? 12 : 14, weight: .semibold))
    .symbolRenderingMode(.monochrome)
    .foregroundStyle(tint)
    .buttonStyle(.plain)
  }
}

/// The 3 fixed presets as a segmented control (custom tweaks deselect all).
struct PresetSegments: View {
  @EnvironmentObject var model: AppModel
  var body: some View {
    Picker("Preset", selection: model.presetBinding) {
      ForEach(Preset.allCases.filter { $0 != .custom }) { Text($0.shortLabel).tag($0) }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
  }
}

/// A lit "BITCRUSH" toggle — glows pink when engaged.
struct BitcrushButton: View {
  @EnvironmentObject var model: AppModel
  var compact = false

  var body: some View {
    let on = model.params.bitcrush
    Button {
      model.update { $0.bitcrush.toggle() }
    } label: {
      Group {
        if compact {
          Image(systemName: "waveform.path")
        } else {
          Label("Bitcrush", systemImage: "waveform.path")
        }
      }
        .font(.system(size: 10, weight: .bold)).textCase(.uppercase)
        .padding(.horizontal, compact ? 8 : 10).padding(.vertical, 6)
        .foregroundStyle(on ? .white : .secondary)
        .background(
          RoundedRectangle(cornerRadius: 7)
            .fill(on ? Color.pink : Color.primary.opacity(0.08))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 7)
            .strokeBorder(on ? Color.pink : Color.primary.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: on ? .pink.opacity(0.6) : .clear, radius: 5)
    }
    .buttonStyle(.plain)
    .help("Crush the high 'fringe' — lo-fi grit on the top end.")
  }
}

/// A lit "FLIP" toggle — the vocal gender flip (male → female, pitch + formants
/// shifted independently). Glows purple when engaged; shows a pulsing hourglass
/// while the flipped intermediate renders.
struct FlipButton: View {
  @EnvironmentObject var model: AppModel
  var compact = false

  var body: some View {
    let on = model.params.vocalFlip
    Button {
      model.toggleFlip()
    } label: {
      Group {
        if model.flipState == .rendering {
          Image(systemName: "hourglass")
            .symbolEffect(.pulse, options: .repeating)
        } else if compact {
          Image(systemName: "person.wave.2")
        } else {
          Label("Flip", systemImage: "person.wave.2")
        }
      }
      .font(.system(size: 10, weight: .bold)).textCase(.uppercase)
      .padding(.horizontal, compact ? 8 : 10).padding(.vertical, 6)
      .foregroundStyle(on ? .white : .secondary)
      .background(
        RoundedRectangle(cornerRadius: 7)
          .fill(on ? Color.purple : Color.primary.opacity(0.08))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 7)
          .strokeBorder(on ? Color.purple : Color.primary.opacity(0.15), lineWidth: 1)
      )
      .shadow(color: on ? .purple.opacity(0.6) : .clear, radius: 5)
    }
    .buttonStyle(.plain)
    .disabled(!on && model.track == nil)
    .help(helpText(on: on))
  }

  private func helpText(on: Bool) -> String {
    if on { return "Vocal flip is on: pitch and formants shifted up for a feminine read." }
    if FlipTools.availableEngines().isEmpty {
      return "Vocal flip needs a pitch shifter: \(FlipTools.installHint(.rubberband))."
    }
    return "Flip the vocals feminine (pitch + formant shift)."
  }
}

// MARK: - the full knob bank

/// The shared rotary control surface: a motion row (speed/pitch/filter/verb) over a
/// 3-band EQ row (low/mid/high). `includeSpeed` is false on decks that drive tempo
/// with a fader instead (the turntable).
struct DeckKnobs: View {
  @EnvironmentObject var model: AppModel
  var tint: Color = .accentColor
  var includeSpeed = true

  private var p: RemixParams { model.params }

  var body: some View {
    VStack(spacing: 16) {
      HStack(alignment: .top, spacing: 18) {
        if includeSpeed {
          Knob(
            title: "Speed", value: model.paramBinding(\.tempo), range: 0.5...1.5, step: 0.01,
            display: String(format: "%.2f×", p.tempo), tint: tint)
        }
        Knob(
          title: "Pitch", value: model.pitchBinding, range: -12...12, step: 1,
          display: "\(p.pitch > 0 ? "+" : "")\(p.pitch)", tint: tint)
        Knob(
          title: "Filter", value: model.paramBinding(\.filter), range: -1...1, step: 0.05,
          display: filterLabel(p.filter), tint: tint)
        Knob(
          title: "Verb", value: model.paramBinding(\.reverb), range: 0...1, step: 0.05,
          display: "\(Int((p.reverb * 100).rounded()))%", tint: tint)
      }
      HStack(alignment: .top, spacing: 18) {
        Knob(
          title: "Low", value: model.paramBinding(\.bass), range: -12...12, step: 1,
          display: eqLabel(p.bass), tint: tint)
        Knob(
          title: "Mid", value: model.paramBinding(\.mid), range: -12...12, step: 1,
          display: eqLabel(p.mid), tint: tint)
        Knob(
          title: "High", value: model.paramBinding(\.high), range: -12...12, step: 1,
          display: eqLabel(p.high), tint: tint)
      }
    }
    .frame(maxWidth: .infinity)  // center the rows within the section
  }

  private func eqLabel(_ g: Double) -> String { "\(g > 0 ? "+" : "")\(Int(g))" }
  private func filterLabel(_ f: Double) -> String {
    abs(f) < 0.02 ? "—" : "\(f < 0 ? "LP" : "HP") \(Int(abs(f) * 100))"
  }
}

// MARK: - automix indicator

/// A slim banner shown while the engine is beatmatch-crossfading into the next track —
/// makes the automix visible so it's tunable by ear.
struct MixingBanner: View {
  @ObservedObject var engine: EnginePlayer
  var body: some View {
    if engine.mixing {
      HStack(spacing: 6) {
        Image(systemName: "arrow.left.arrow.right")
          .symbolEffect(.pulse, options: .repeating)
        Text("beatmatching into the next track…")
      }
      .font(.caption.weight(.medium))
      .foregroundStyle(.pink)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 6)
      .background(Color.pink.opacity(0.12), in: Capsule())
      .transition(.opacity)
    }
  }
}

// MARK: - meters

/// elapsed / total counter on the remixed timeline.
struct DeckCounter: View {
  @ObservedObject var engine: EnginePlayer
  var tint: Color = .secondary
  var body: some View {
    let total = engine.effectiveDuration
    HStack {
      Text(formatDuration(engine.progress * total))
      Spacer()
      Text(formatDuration(total))
    }
    .font(.system(size: 11, weight: .medium, design: .monospaced))
    .foregroundStyle(tint)
  }
}
