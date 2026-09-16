import Foundation

/// Never edit config in place. Write a sibling temp file, fsync it, then
/// `rename(2)` — which is atomic within a filesystem — so a crash mid-write
/// leaves either the old file or the new one, never a truncated hybrid.
public enum AtomicWrite {
    public static func write(_ data: Data, to url: URL, backup: Bool = false) throws {
        try Paths.assertNotDefaultState(url)
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        if backup, fm.fileExists(atPath: url.path) {
            let stamp = Int(Date().timeIntervalSince1970 * 1000)
            let backupURL = dir.appending(path: "\(url.lastPathComponent).backup.\(stamp)")
            try? fm.copyItem(at: url, to: backupURL)
        }

        let temp = dir.appending(path: ".\(url.lastPathComponent).tmp.\(UUID().uuidString)")
        let handle = try FileHandle(forWritingTo: {
            fm.createFile(atPath: temp.path, contents: nil,
                          attributes: [.posixPermissions: 0o600])
            return temp
        }())
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
        _ = try fm.replaceItemAt(url, withItemAt: temp)
    }
}
