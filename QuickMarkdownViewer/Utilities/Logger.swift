import Foundation
import OSLog

/// Minimal logging facade for QuickMarkdownViewer.
///
/// We keep logs centralised so messages are consistent and easy to filter
/// in Console.app or collected diagnostics.
enum Logger {
    /// Reverse-DNS subsystem for log categorisation.
    private static let subsystem = "com.naohideyamamoto.quickmarkdownviewer"

    /// Shared log category used across the app.
    private static let category = "QuickMarkdownViewer"

    /// Underlying modern unified logger instance.
    private static let logger = os.Logger(subsystem: subsystem, category: category)

    /// Whether non-error diagnostic logs should be emitted.
    ///
    /// Default behaviour is intentionally quiet to reduce Xcode console noise
    /// during normal use. When deeper diagnostics are needed, set the process
    /// environment variable `QMV_VERBOSE_LOGS=1` (or `true`) in the run scheme.
    private static let isInformationalLoggingEnabled: Bool = {
        guard let value = ProcessInfo.processInfo.environment["QMV_VERBOSE_LOGS"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else {
            return false
        }

        return value == "1" || value == "true"
    }()

    /// Writes an informational message.
    static func info(_ message: String) {
        guard isInformationalLoggingEnabled else {
            return
        }

        logger.info("\(message, privacy: .public)")
    }

    /// Writes an error message.
    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
