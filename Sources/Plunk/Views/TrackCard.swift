import PlunkKit
import SwiftUI

func formatDuration(_ seconds: Double) -> String {
  guard seconds.isFinite, seconds > 0 else { return "0:00" }
  let total = Int(seconds.rounded())
  return String(format: "%d:%02d", total / 60, total % 60)
}

struct TrackCard<Content: View>: View {
  let meta: TrackMeta
  let pulling: Bool
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 12) {
        artwork
        VStack(alignment: .leading, spacing: 2) {
          Text(meta.title).font(.headline).lineLimit(1)
          Text(meta.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
          HStack(spacing: 6) {
            if meta.duration > 0 {
              Text(formatDuration(meta.duration)).monospacedDigit()
            }
            Text(meta.source.lowercased())
              .padding(.horizontal, 6).padding(.vertical, 1)
              .background(.quaternary, in: Capsule())
          }
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.top, 1)
        }
        Spacer(minLength: 0)
      }

      if pulling {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Pulling highest-quality audio…")
            .font(.callout).foregroundStyle(.secondary)
        }
      }

      content
    }
    .plunkCard()
  }

  @ViewBuilder private var artwork: some View {
    let shape = RoundedRectangle(cornerRadius: 8)
    if let thumb = meta.thumbnail, let url = URL(string: thumb) {
      AsyncImage(url: url) { image in
        image.resizable().aspectRatio(contentMode: .fill)
      } placeholder: {
        shape.fill(.quaternary)
      }
      .frame(width: 64, height: 64)
      .clipShape(shape)
      .overlay(shape.strokeBorder(Color(nsColor: .separatorColor)))
    } else {
      shape.fill(.quaternary)
        .frame(width: 64, height: 64)
        .overlay(Image(systemName: "music.note").imageScale(.large).foregroundStyle(.secondary))
    }
  }
}

struct ResolveSkeleton: View {
  var body: some View {
    HStack(spacing: 12) {
      RoundedRectangle(cornerRadius: 8).fill(.quaternary).frame(width: 64, height: 64)
      VStack(alignment: .leading, spacing: 8) {
        RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 180, height: 13)
        RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 120, height: 11)
      }
      Spacer()
    }
    .plunkCard()
    .redacted(reason: .placeholder)
  }
}
