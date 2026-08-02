import SwiftUI

/// Placeholder per SPEC.md v1 scope cuts.
struct ProfileView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.white.opacity(0.6))
            Text("Profile")
                .font(.title2.bold())
                .foregroundStyle(.white)
                .accessibilityIdentifier("profile.title")
            Text("Coming soon").foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
    }
}
