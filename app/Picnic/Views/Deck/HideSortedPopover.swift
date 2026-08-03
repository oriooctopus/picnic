import SwiftUI

struct HideSortedPopover: View {
    @Binding var hideSorted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Hide:")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                hideSorted.toggle()
            } label: {
                HStack {
                    Image(systemName: hideSorted ? "checkmark.square.fill" : "square")
                    Text("Sorted pics")
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("deck.hideSortedToggle")

            Divider()

            Label("More settings", systemImage: "gearshape.fill")
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 220)
    }
}
