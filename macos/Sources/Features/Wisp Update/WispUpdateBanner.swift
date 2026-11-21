import SwiftUI

/// Shows the updater's state at the bottom of the tab sidebar: a new version
/// with an Update button, progress, and the restart prompt.
struct WispUpdateBanner: View {
    @ObservedObject private var updater = WispUpdater.shared

    var body: some View {
        switch updater.state {
        case .idle:
            EmptyView()

        case .checking:
            banner(icon: "arrow.triangle.2.circlepath", tint: .secondary) {
                Text("Checking for updates…")
            }

        case .upToDate:
            banner(icon: "checkmark.circle.fill", tint: .green) {
                Text("Wisp is up to date")
            }

        case .available(let summary):
            banner(icon: "arrow.down.circle.fill", tint: .accentColor) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Update available")
                        .fontWeight(.semibold)
                    Text(summary)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    actions {
                        Button("Update", action: updater.update)
                            .buttonStyle(.borderedProminent)
                        Button("Later", action: updater.dismiss)
                            .buttonStyle(.borderless)
                    }
                    .padding(.top, 2)
                }
            }

        case .updating:
            banner(icon: nil, tint: .accentColor) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Updating Wisp…")
                        Text(updater.buildsFromSource ? "Building takes a few minutes" : "Downloading the new version")
                            .foregroundStyle(.secondary)
                    }
                }
            }

        case .readyToRestart:
            banner(icon: "sparkles", tint: .accentColor) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Update installed")
                        .fontWeight(.semibold)
                    Button("Restart Wisp", action: updater.restart)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }

        case .failed(let message):
            banner(icon: "exclamationmark.triangle.fill", tint: .orange) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(message)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                    actions {
                        Button("Show Log", action: updater.openLog)
                        Button("Dismiss", action: updater.dismiss)
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    /// Buttons side by side, or stacked when the sidebar is too narrow for
    /// that, so their titles are never cut off.
    private func actions<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let buttons = content()
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { buttons }
            VStack(alignment: .leading, spacing: 4) { buttons }
        }
        .controlSize(.small)
    }

    private func banner<Content: View>(
        icon: String?,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if let icon {
                Image(systemName: icon)
                    .foregroundStyle(tint)
            }
            content()
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.07)))
    }
}
