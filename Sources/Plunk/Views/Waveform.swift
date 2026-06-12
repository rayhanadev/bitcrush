import SwiftUI

/// A dense, seekable RMS waveform — one bar per data point, the loud/quiet heights
/// giving it a real silhouette. Used inside every deck skin. Drag/tap to seek.
struct Waveform: View {
  var peaks: [Float]
  var progress: Double
  var height: CGFloat = 36
  var onSeek: (Double) -> Void

  var body: some View {
    GeometryReader { geo in
      let width = geo.size.width
      Group {
        if peaks.isEmpty {
          // still decoding — thin progress bar fallback
          ZStack(alignment: .leading) {
            // explicit colors so the inherited deck .tint doesn't recolor the track
            Capsule().fill(Color.secondary.opacity(0.3)).frame(height: 3)
            Capsule().fill(Color.accentColor).frame(width: width * progress, height: 3)
          }
          .frame(maxHeight: .infinity)
        } else {
          Canvas { ctx, size in
            let n = peaks.count
            let barW = max(1, size.width / CGFloat(n) - 1.5)
            let mid = size.height / 2
            for i in 0..<n {
              let h = max(2, CGFloat(peaks[i]) * size.height * 0.92)
              let x = size.width * CGFloat(i) / CGFloat(n)
              let played = (Double(i) + 0.5) / Double(n) <= progress
              let rect = CGRect(x: x, y: mid - h / 2, width: barW, height: h)
              ctx.fill(
                Path(roundedRect: rect, cornerRadius: barW / 2),
                with: .color(played ? Color.accentColor : Color.secondary.opacity(0.3)))
            }
          }
        }
      }
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onEnded { value in
            onSeek(min(1, max(0, value.location.x / width)))
          })
    }
    .frame(height: height)
  }
}
