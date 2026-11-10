//
//  DottieFileLoader.swift
//  leanring-buddy
//
//  Loads Dottie's own saved lists (helpers, routines, shortcuts, the
//  conversation). Loads used to be "try?": a file that could not be read
//  as expected looked the same as no file at all, the list started empty,
//  and the next save wrote that empty list over everything the user had.
//  Here an unreadable file is said in the log and a copy of it is kept
//  beside it first, so what was in it can still be recovered.
//

import Foundation

nonisolated enum DottieFileLoader {

    /// The saved value in the file, or nil when there is no file or it
    /// can't be read as that type. In the second case the reason goes to
    /// the log and the file is copied to `unreadableCopyURL(for:)`.
    static func load<Value: Decodable>(
        _ valueType: Value.Type,
        from fileURL: URL,
        decoder: JSONDecoder = JSONDecoder(),
        callerFile: String = #fileID
    ) -> Value? {
        // No file yet is the normal first-launch case, not a problem.
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        let fileData: Data
        do {
            fileData = try Data(contentsOf: fileURL)
        } catch {
            DottieLog.error("Could not read the file \(fileURL.lastPathComponent): \(error.localizedDescription)", callerFile: callerFile)
            return nil
        }

        do {
            return try decoder.decode(valueType, from: fileData)
        } catch {
            DottieLog.error("Could not understand the file \(fileURL.lastPathComponent), keeping a copy of it: \(String(describing: error))", callerFile: callerFile)
            keepUnreadableCopy(of: fileData, originalFileURL: fileURL)
            return nil
        }
    }

    /// Where the copy of an unreadable file is kept: "routines.json"
    /// becomes "routines.unreadable.json" in the same folder.
    static func unreadableCopyURL(for fileURL: URL) -> URL {
        let fileExtension = fileURL.pathExtension
        let nameWithoutExtension = fileURL.deletingPathExtension().lastPathComponent
        let copyName = fileExtension.isEmpty
            ? "\(nameWithoutExtension).unreadable"
            : "\(nameWithoutExtension).unreadable.\(fileExtension)"
        return fileURL.deletingLastPathComponent().appendingPathComponent(copyName)
    }

    private static func keepUnreadableCopy(of fileData: Data, originalFileURL: URL) {
        // Not through DottieFileSaver: a failure here must not hide the
        // decoding error already logged above with a second, louder line.
        try? fileData.write(to: unreadableCopyURL(for: originalFileURL), options: .atomic)
    }
}
