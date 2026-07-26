import SwiftUI

/// Native About window contents: app identity, the versions that identify
/// this exact build (app + build number, git commit, Rust core), and the
/// Synology API versions it talks to.
///
/// Styled to match the app's other plain informational views (see
/// EmptyLibraryView / StoreFailedView): a glyph, a title, muted captions,
/// and monospaced text for anything version or hash shaped. Deliberately
/// plain and native, not flashy.
struct AboutView: View {
    let info: AboutInfo

    init(info: AboutInfo = .current()) {
        self.info = info
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text("MySynology Photos")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Version \(info.versionLine)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                buildRow(label: "Commit", value: info.gitCommit)
                buildRow(label: "Core", value: info.coreVersion)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Synology API versions")
                    .font(.subheadline)
                    .fontWeight(.medium)
                ForEach(info.apiVersions) { api in
                    HStack(alignment: .firstTextBaseline) {
                        Text(api.name)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        Text("v\(api.version)")
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                Text("Versions this build requests. Advertised ranges on the NAS are documented in the project docs.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
        .frame(width: 340)
        .accessibilityIdentifier("about.panel")
    }

    /// One "Label   value" row, value rendered monospaced since every value
    /// here (a git SHA, a semantic version) reads best fixed-width.
    private func buildRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}
