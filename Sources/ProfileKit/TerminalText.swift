import Foundation

public enum TerminalText {
    /// Strips control characters — ESC above all — so a session title or
    /// working directory taken from a transcript cannot inject an escape
    /// sequence into terminal output. Titles are set by the user or generated
    /// from conversation content, which makes them the one string the CLI
    /// prints that nobody trustworthy chose.
    public static func sanitize(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.filter { !isControl($0) })
        return String(scalars)
    }

    static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F, 0x80...0x9F: return true
        default: return false
        }
    }
}
