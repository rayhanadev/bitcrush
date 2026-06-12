import SwiftUI

struct SearchBar: View {
  @Binding var text: String
  var busy: Bool
  var onSubmit: () -> Void

  @FocusState private var focused: Bool

  private var isURL: Bool { text.lowercased().hasPrefix("http") }

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: isURL ? "link" : "magnifyingglass")
        .foregroundStyle(.secondary)

      TextField("Paste a link or search a song", text: $text)
        .textFieldStyle(.plain)
        .font(.body)
        .focused($focused)
        .onSubmit(onSubmit)
        .disabled(busy)
        .task {
          // defer one runloop turn so the field is in the responder chain first
          try? await Task.sleep(nanoseconds: 50_000_000)
          focused = true
        }

      if busy {
        ProgressView().controlSize(.small)
      } else if !text.isEmpty {
        Button {
          text = ""
          focused = true
        } label: {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tertiary)
        .help("Clear")
      }
    }
    .padding(.horizontal, 10)
    .frame(height: 34)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
  }
}
