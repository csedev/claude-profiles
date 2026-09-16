import Foundation

/// Never edit config in place. Write a sibling temp file, fsync it, then
/// `rename(2)` — which is atomic within a filesystem — so a crash mid-write
/// leaves either the old file or the new one, never a truncated hybrid.
public enum AtomicWrite {
    /// How many timestamped backups of one file survive. Every launch and every
    /// `sync` writes one, and the files being protected carry account identity
    /// and MCP server environments — a year of daily launches should not leave
    /// hundreds of copies of those behind.
    public static let backupsToKeep = 5

    public static func write(_ data: Data, to url: URL, backup: Bool = false) throws {
        try Paths.assertNotDefaultState(url)
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try Paths.createPrivateDirectory(dir)

        if backup, fm.fileExists(atPath: url.path) {
            let stamp = Int(Date().timeIntervalSince1970 * 1000)
            let backupURL = dir.appending(path: "\(url.lastPathComponent).backup.\(stamp)")
            try? fm.copyItem(at: url, to: backupURL)
            pruneBackups(of: url)
        }

        let temp = dir.appending(path: ".\(url.lastPathComponent).tmp.\(UUID().uuidString)")
        fm.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600])
        do {
            let handle = try FileHandle(forWritingTo: temp)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            // The temp file's own mode (0600) wins over whatever the file being
            // replaced had, so a config that was world-readable does not stay so.
            _ = try fm.replaceItemAt(url, withItemAt: temp, options: [.usingNewMetadataOnly])
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    /// Backups of `url`, newest first.
    public static func backups(of url: URL) -> [URL] {
        let dir = url.deletingLastPathComponent()
        let prefix = "\(url.lastPathComponent).backup."
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return entries
            .compactMap { name -> (stamp: Int, url: URL)? in
                guard name.hasPrefix(prefix), let stamp = Int(name.dropFirst(prefix.count))
                else { return nil }
                return (stamp, dir.appending(path: name))
            }
            .sorted { $0.stamp > $1.stamp }
            .map(\.url)
    }

    static func pruneBackups(of url: URL) {
        for stale in backups(of: url).dropFirst(backupsToKeep) {
            try? FileManager.default.removeItem(at: stale)
        }
    }
}
