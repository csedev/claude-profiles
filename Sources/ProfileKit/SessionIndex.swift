import Foundation

/// A Claude Code session found on disk.
public struct SessionRecord: Sendable, Identifiable, Equatable {
    public enum Kind: String, Sendable {
        /// Cloud-synced. Stamped with an owner account server-side, so it can
        /// only ever be opened by the account that created it.
        case bridge
        /// Local CLI transcript with no owner stamp.
        case local
    }

    public let id: String
    public let kind: Kind
    public let profileID: UUID?
    public let profileLabel: String
    public let ownerAccountUUID: String?
    public let title: String?
    public let cwd: String?
    public let modified: Date
    public let sizeBytes: Int
    public let transcript: URL

    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let cwd { return URL(fileURLWithPath: cwd).lastPathComponent }
        return String(id.prefix(8))
    }
}

public enum SessionIndex {
    /// Only the head of each transcript is read. These files reach hundreds of
    /// megabytes in aggregate, and everything identifying a session — its type,
    /// owner stamp, cwd, and title — appears in the first few lines.
    static let headBytes = 64 * 1024

    static func readHead(_ url: URL, limit: Int = headBytes) -> [[String: Any]] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit), !data.isEmpty else { return [] }

        return data.split(separator: UInt8(ascii: "\n")).compactMap { slice in
            try? JSONSerialization.jsonObject(with: Data(slice)) as? [String: Any]
        }
    }

    static func record(
        transcript: URL, profileID: UUID?, profileLabel: String
    ) -> SessionRecord? {
        let lines = readHead(transcript)
        guard let first = lines.first,
            let sessionID = first["sessionId"] as? String
        else { return nil }

        let owner = first["ownerAccountUuid"] as? String
        let kind: SessionRecord.Kind = owner != nil ? .bridge : .local

        // Title and cwd may appear on any of the early lines.
        let title = lines.compactMap { $0["customTitle"] as? String }.last
        let cwd = lines.compactMap { $0["cwd"] as? String }.first

        let attributes = try? FileManager.default.attributesOfItem(atPath: transcript.path)
        return SessionRecord(
            id: sessionID,
            kind: kind,
            profileID: profileID,
            profileLabel: profileLabel,
            ownerAccountUUID: owner,
            title: title,
            cwd: cwd,
            modified: (attributes?[.modificationDate] as? Date) ?? .distantPast,
            sizeBytes: (attributes?[.size] as? Int) ?? 0,
            transcript: transcript)
    }

    static func transcripts(inProjectsDir dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return projectDirs.flatMap { projectDir -> [URL] in
            (try? fm.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "jsonl" } ?? []
        }
    }

    /// Every session across every profile, newest first.
    ///
    /// Sessions are *attributed*, never merged. A bridge session belongs to the
    /// account that created it — the desktop app partitions its own list by
    /// account UUID and grouping lives server-side — so the honest thing to
    /// offer is one index that says which account owns what, and routes you to
    /// the right window.
    public static func all(limit: Int = 500) -> [SessionRecord] {
        var records: [SessionRecord] = []

        records += transcripts(inProjectsDir: Paths.defaultConfigDir.appending(path: "projects"))
            .compactMap { record(transcript: $0, profileID: nil, profileLabel: "Default") }

        for profile in ProfileStore.all() {
            records += transcripts(inProjectsDir: profile.paths.config.appending(path: "projects"))
                .compactMap {
                    record(transcript: $0, profileID: profile.id, profileLabel: profile.label)
                }
        }

        return Array(records.sorted { $0.modified > $1.modified }.prefix(limit))
    }

    public static func search(_ needle: String, limit: Int = 50) -> [SessionRecord] {
        let lowered = needle.lowercased()
        guard !lowered.isEmpty else { return Array(all().prefix(limit)) }
        return Array(
            all().filter {
                $0.displayTitle.lowercased().contains(lowered)
                    || ($0.cwd?.lowercased().contains(lowered) ?? false)
                    || $0.id.lowercased().hasPrefix(lowered)
            }.prefix(limit))
    }
}
