import ProfileKit
import SwiftUI

struct UsageBar: View {
    let title: String
    let percent: Double?

    private var color: Color {
        switch percent ?? 0 {
        case ..<60: .green
        case ..<85: .orange
        default: .red
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(color)
                        .frame(width: geo.size.width * min(max((percent ?? 0) / 100, 0), 1))
                }
            }
            .frame(height: 6)
            Text(percent.map { "\(Int($0.rounded()))%" } ?? "—")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }
}

struct ProfileCard: View {
    let row: ProfileRow
    let onLaunch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(row.isRunning ? .green : .secondary.opacity(0.4))
                    .frame(width: 7, height: 7)
                Text(row.label).font(.headline)
                if row.isDefault {
                    Text("read-only")
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .help(
                            "Claude's own profile. This app reads it but never writes to it — "
                                + "its settings, sessions and login are left exactly as Claude manages them.")
                }
                Spacer()
                Button(row.isRunning ? "Focus" : "Launch", action: onLaunch)
                    .buttonStyle(.borderless)
                    .font(.caption)
            }

            Text(row.email ?? "not signed in")
                .font(.caption)
                .foregroundStyle(.secondary)

            UsageBar(title: "5-hour", percent: row.fiveHour)
            UsageBar(title: "Weekly", percent: row.weekly)
            ForEach(row.extraWindows) { extra in
                UsageBar(title: extra.window.title, percent: extra.value)
            }

            if let count = row.projectCount {
                Text("\(count) project settings")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct SessionRow: View {
    let session: SessionRecord
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 6) {
                // Cloud sessions can only be opened by their owning account.
                Image(systemName: session.kind == .bridge ? "cloud" : "terminal")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.displayTitle).font(.caption).lineLimit(1)
                    Text(session.profileLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text(session.modified.formatted(.relative(presentation: .numeric)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct MenuContent: View {
    @Bindable var model: ProfilesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Claude Profiles").font(.headline)
                Spacer()
                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }

            ForEach(model.rows) { row in
                ProfileCard(row: row) { model.launch(row) }
            }

            if !model.sessions.isEmpty {
                Divider()
                Text("RECENT SESSIONS")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                ForEach(model.sessions) { session in
                    SessionRow(session: session) { model.reveal(session) }
                }
            }

            if model.loginItemNeedsApproval {
                HStack(spacing: 6) {
                    Text("Login item needs approval")
                        .font(.caption2).foregroundStyle(.orange)
                    Button("Open Settings") { model.openLoginItemSettings() }
                        .buttonStyle(.borderless).font(.caption2)
                }
            }

            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            Divider()

            HStack {
                if let refreshed = model.lastRefresh {
                    Text("Updated \(refreshed.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                Toggle(
                    "Open at login",
                    isOn: Binding(
                        get: { model.launchesAtLogin },
                        set: { model.setLaunchAtLogin($0) })
                )
                .toggleStyle(.checkbox).font(.caption2)
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless).font(.caption)
            }
        }
        .padding(12)
        .frame(width: 340)
    }
}
