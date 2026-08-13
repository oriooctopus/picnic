import SwiftUI

/// Placeholder per SPEC.md v1 scope cuts.
struct ProfileView: View {
    /// "1.0 (42)"-style short-version/build-number string, read straight
    /// from the bundle rather than hardcoded — this is the only place in
    /// the app that surfaces which build is actually installed, which
    /// mattered concretely during the filmstrip/hideSorted redesign: with
    /// no version string anywhere, there was no way to confirm which build
    /// was on the owner's phone while debugging a report against it.
    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let shortVersion = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "v\(shortVersion) (\(build))"
    }

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
            Text(versionString)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.3))
                .accessibilityIdentifier("profile.version")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
    }
}
