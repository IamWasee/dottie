//
//  DottieFileSaver.swift
//  leanring-buddy
//
//  Saves Dottie's own files (settings, memories, lists) and says so in the
//  log when a save fails. Saves used to be "try?", so a full disk or a
//  missing folder lost what the user had just changed with no trace
//  anywhere. Every save here is atomic: the file is written beside the old
//  one and swapped in, so a crash mid-save can't leave half a file.
//

import Foundation

nonisolated enum DottieFileSaver {

    /// Saves the data to the file. Returns false, and writes the reason to
    /// the log, when it could not be saved.
    @discardableResult
    static func save(_ data: Data, to fileURL: URL, callerFile: String = #fileID) -> Bool {
        do {
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            DottieLog.error("Could not save the file \(fileURL.lastPathComponent): \(error.localizedDescription)", callerFile: callerFile)
            return false
        }
    }

    /// Saves the text to the file as UTF-8. Returns false, and writes the
    /// reason to the log, when it could not be saved.
    @discardableResult
    static func save(text: String, to fileURL: URL, callerFile: String = #fileID) -> Bool {
        save(Data(text.utf8), to: fileURL, callerFile: callerFile)
    }
}
