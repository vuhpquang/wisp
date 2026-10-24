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

        case .available(let commits, let latest):
            banner(icon: "arrow.down.circle.fill", tint: .accentColor) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Update available")
                        .fontWeight(.semibold)
                    Text(commits == 1 ? latest : "\(commits) changes · \(latest)")
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    HStack {
                        Button("Update", action: updater.update)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        Button("Later", action: updater.dismiss)
                            .buttonStyle(.borderless)
                            .controlSize(.small)
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
                        Text("Building takes a few minutes")
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
                VStack(alignment: .leading, spacing: 4) {
                    Text(message)
                        .lineLimit(3)
                    HStack {
                        Button("Show Log", action: updater.openLog)
                            .controlSize(.small)
                        Button("Dismiss", action: updater.dismiss)
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                    }
                }
            }
        }
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
