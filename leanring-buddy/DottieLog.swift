//
//  DottieLog.swift
//  leanring-buddy
//
//  Dottie's log. Lines go to the Mac's own log (Console, or
//  `log show --predicate 'process == "Dottie"'`), with a level and the
//  file they came from as the category; print() lines never reached it.
//  The words written in the code always show. The values put into a line
//  (what the user said, a task's text, an error) are hidden as ‹…› unless
//  the app is run from Xcode or details are switched on with
//  `defaults write com.dottie.Dottie DottieLogShowsDetails -bool YES`,
//  so nothing personal sits in the log of someone who didn't ask for it.
//

import Foundation
import os

/// One log line. Written like any string, "Screen task failed: \(reason)";
/// it remembers which parts were values so they can be hidden.
nonisolated struct DottieLogMessage: ExpressibleByStringInterpolation, Sendable {
    /// What stands in for a hidden value.
    static let hiddenValueMarker = "‹…›"

    let textWithDetails: String
    let textWithoutDetails: String

    init(stringLiteral value: String) {
        textWithDetails = value
        textWithoutDetails = value
    }

    init(stringInterpolation: StringInterpolation) {
        textWithDetails = stringInterpolation.textWithDetails
        textWithoutDetails = stringInterpolation.textWithoutDetails
    }

    nonisolated struct StringInterpolation: StringInterpolationProtocol {
        var textWithDetails = ""
        var textWithoutDetails = ""

        init(literalCapacity: Int, interpolationCount: Int) {
            textWithDetails.reserveCapacity(literalCapacity + interpolationCount * 16)
            textWithoutDetails.reserveCapacity(literalCapacity + interpolationCount * DottieLogMessage.hiddenValueMarker.count)
        }

        mutating func appendLiteral(_ literal: String) {
            textWithDetails += literal
            textWithoutDetails += literal
        }

        mutating func appendInterpolation<Value>(_ value: Value) {
            textWithDetails += String(describing: value)
            textWithoutDetails += DottieLogMessage.hiddenValueMarker
        }

        /// A value that is never personal (a model name, a token count), so
        /// it always shows: `"\(public: modelName)"`.
        mutating func appendInterpolation<Value>(public value: Value) {
            textWithDetails += String(describing: value)
            textWithoutDetails += String(describing: value)
        }
    }
}

nonisolated enum DottieLog {
    /// The UserDefaults key that shows the values in every line.
    static let showsDetailsDefaultsKey = "DottieLogShowsDetails"

    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.dottie.Dottie"

    /// Something that happened, worth having when reading back what Dottie did.
    static func notice(_ message: DottieLogMessage, callerFile: String = #fileID) {
        logger(forCallerFile: callerFile).notice("\(shownText(of: message), privacy: .public)")
    }

    /// Something went wrong and Dottie carried on another way.
    static func warning(_ message: DottieLogMessage, callerFile: String = #fileID) {
        logger(forCallerFile: callerFile).warning("\(shownText(of: message), privacy: .public)")
    }

    /// Something failed and the user's request could not be done.
    static func error(_ message: DottieLogMessage, callerFile: String = #fileID) {
        logger(forCallerFile: callerFile).error("\(shownText(of: message), privacy: .public)")
    }

    /// The line as it is written to the log: with its values in a build run
    /// from Xcode or when details are switched on, otherwise without them.
    static func shownText(of message: DottieLogMessage, showsDetails: Bool = DottieLog.showsDetails) -> String {
        showsDetails ? message.textWithDetails : message.textWithoutDetails
    }

    static var showsDetails: Bool {
        #if DEBUG
        return true
        #else
        return UserDefaults.standard.bool(forKey: showsDetailsDefaultsKey)
        #endif
    }

    /// "Dottie/DottieScreenTaskRunner.swift" → "DottieScreenTaskRunner".
    static func category(forCallerFile callerFile: String) -> String {
        let fileName = callerFile.split(separator: "/").last.map(String.init) ?? callerFile
        return fileName.hasSuffix(".swift") ? String(fileName.dropLast(".swift".count)) : fileName
    }

    private static func logger(forCallerFile callerFile: String) -> Logger {
        Logger(subsystem: subsystem, category: category(forCallerFile: callerFile))
    }
}
