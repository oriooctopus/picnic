import SwiftUI

enum RootTab {
    case myLife, utilities, profile
}

/// Custom floating pill tab bar matching the reference screenshots. SPEC.md
/// scopes exactly 3 tabs — Deck and Compare are pushed from My Life, not
/// tabs themselves.
struct RootTabView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab: RootTab = .myLife

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            Group {
                switch selectedTab {
                case .myLife: MyLifeView()
                case .utilities: UtilitiesView()
                case .profile: ProfileView()
                }
            }

            MirrorSyncBanner()
                .padding(.bottom, 100)

            bottomBar
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 40) {
            tabButton(.myLife, systemImage: "square.grid.2x2.fill", identifier: "tab.myLife")
            tabButton(.utilities, systemImage: "square.stack.3d.up.fill", identifier: "tab.utilities")
            ZStack(alignment: .topTrailing) {
                tabButton(.profile, systemImage: "person.crop.circle.fill", identifier: "tab.profile")
                if appState.hasUnviewedProfileBadge {
                    Circle().fill(Color.red).frame(width: 8, height: 8).offset(x: 2, y: -2)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background(Capsule().fill(Color(white: 0.12)))
        .padding(.bottom, 12)
    }

    private func tabButton(_ tab: RootTab, systemImage: String, identifier: String) -> some View {
        Button {
            selectedTab = tab
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 20))
                .foregroundStyle(selectedTab == tab ? .white : .gray)
        }
        .accessibilityIdentifier(identifier)
    }
}
