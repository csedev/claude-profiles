import Foundation

public enum SecureInput {
    /// Reads a line from the terminal without echoing it.
    ///
    /// `readLine()` echoes, which would leave a long-lived bearer token sitting
    /// in the terminal's scrollback — visible to anyone glancing at the screen,
    /// and captured by any tool that records the session. Keeping it out of
    /// argv and shell history is not enough on its own.
    ///
    /// `getpass(3)` would be the obvious answer but truncates at 128 bytes on
    /// Darwin, and these tokens are longer, so echo is toggled directly.
    ///
    /// When stdin is not a terminal (a pipe, a script) this reads normally —
    /// there is no echo to suppress.
    public static func readSecret() -> String? {
        guard isatty(STDIN_FILENO) == 1 else {
            return readLine(strippingNewline: true)
        }

        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else {
            return readLine(strippingNewline: true)
        }

        var muted = original
        muted.c_lflag &= ~tcflag_t(ECHO)
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &muted) == 0 else {
            return readLine(strippingNewline: true)
        }
        defer {
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
            // The newline the user typed was swallowed along with the echo.
            print("")
        }

        return readLine(strippingNewline: true)
    }
}
