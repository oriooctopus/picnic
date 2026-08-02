import SwiftUI

struct SmartCollectionTile: View {
    let kind: SmartCollectionKind
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(white: 0.15))
                .aspectRatio(0.85, contentMode: .fit)
                .overlay(
                    Image(systemName: kind.iconName)
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.8))
                )
            Text(kind.title).font(.subheadline.bold()).foregroundStyle(.white)
            Text("\(count)").font(.caption).foregroundStyle(.white.opacity(0.6))
        }
    }
}
