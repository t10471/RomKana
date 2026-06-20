import Foundation
import os

// Centralized logging. View live with:
//   log stream --predicate 'subsystem == "com.toshinao.romkana"' --level debug
enum Log {
    private static let logger = Logger(subsystem: "com.toshinao.romkana", category: "ime")

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    static func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
