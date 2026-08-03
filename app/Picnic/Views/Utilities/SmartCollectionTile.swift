import SwiftUI

struct SmartCollectionTile: View {
    let kind: SmartCollectionKind
    let count: Int

    private var countString: String {
        count.formatted(.number)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Standard cell pattern (see MonthCardView): Color.clear drives
            // sizing via .aspectRatio(.fit) off the grid's own flexible
            // column width, no GeometryReader involved.
            Color.clear
                .aspectRatio(0.85, contentMode: .fit)
                .overlay { Color(white: 0.15) }
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(alignment: .topLeading) {
                    Image(systemName: kind.iconName)
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                        .padding(10)
                }
            Text(kind.title).font(.subheadline.bold()).foregroundStyle(.white)
            Text(countString).font(.caption).foregroundStyle(.white.opacity(0.6))
        }
        // Single AX element for the whole tile — without this, the identifier
        // applied at the call site bleeds onto the icon overlay and both Text
        // layers as separate elements with their own (mismatched) frames.
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("smartCollection.tile.\(kind.rawValue)")
        .accessibilityLabel("\(kind.title), \(count)")
    }
}
