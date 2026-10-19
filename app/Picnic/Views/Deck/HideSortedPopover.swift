import SwiftUI

struct HideSortedPopover: View {
    @Binding var hideSorted: Bool
    @Binding var offlineOnly: Bool
    /// Unsorted, downloaded cards after the current one (`DeckViewModel.offlineReadyAhead`).
    var offlineReadyAhead: Int
    var markSortedToHere: () -> Void = {}
    /// False for a remote-album deck: "Mark sorted till here" would mass-keep
    /// (= queue server downloads for) every earlier item in one tap.
    var showsMarkSortedToHere = true

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
            // Checked/unchecked is only encoded visually (SF Symbol swap
            // above) — nothing exposed it as a readable state, so a UI test
            // could tap this toggle but never confirm afterwards which way
            // it landed. Explicit accessibilityValue gives XCUITest a
            // stable "on"/"off" string to assert on instead of trying to
            // infer state from the symbol name.
            .accessibilityValue(hideSorted ? "on" : "off")

            Button {
                offlineOnly.toggle()
            } label: {
                HStack {
                    Image(systemName: offlineOnly ? "checkmark.square.fill" : "square")
                    Text("Offline only")
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("deck.offlineOnlyToggle")
            // Same reason as the hideSorted toggle: the check is only a symbol swap.
            .accessibilityValue(offlineOnly ? "on" : "off")

            // How many swipes remain with no network. The prefetcher works
            // toward 150; this shows how far along it is.
            Text("\(offlineReadyAhead) ready offline")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("deck.offlineReadyCount")

            if showsMarkSortedToHere {
                Divider()

                Button(action: markSortedToHere) {
                    Label("Mark sorted till here", systemImage: "checkmark.circle")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("deck.markSortedToHere")
            }

            Divider()

            Label("More settings", systemImage: "gearshape.fill")
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 220)
    }
}
