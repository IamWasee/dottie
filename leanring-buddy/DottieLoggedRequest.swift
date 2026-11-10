//
//  DottieLoggedRequest.swift
//  leanring-buddy
//
//  Sends a web request for the features that carry on without an answer
//  (a search, a preview picture, a phone text) and says so in the log when
//  the request fails. These used to be "try?", so no internet, a timeout
//  or a refused connection looked the same as an empty answer and left no
//  trace of why nothing happened. Only the server's name is logged, never
//  the whole address, because some addresses carry a key.
//

import Foundation

nonisolated enum DottieLoggedRequest {

    /// Sends the request. Returns nil, and writes the reason to the log,
    /// when no answer came back. A request that was cancelled on purpose
    /// is not logged.
    static func send(
        _ request: URLRequest,
        session: URLSession = .shared,
        callerFile: String = #fileID
    ) async -> (Data, URLResponse)? {
        do {
            return try await session.data(for: request)
        } catch {
            if !isCancellation(error) {
                let serverName = request.url?.host ?? "an unknown server"
                DottieLog.warning("A request to \(serverName) failed: \(error.localizedDescription)", callerFile: callerFile)
            }
            return nil
        }
    }

    /// Fetches the address with a plain GET. Returns nil, and writes the
    /// reason to the log, when no answer came back.
    static func fetch(
        from address: URL,
        session: URLSession = .shared,
        callerFile: String = #fileID
    ) async -> (Data, URLResponse)? {
        await send(URLRequest(url: address), session: session, callerFile: callerFile)
    }

    /// Whether the error only says the request was stopped on purpose
    /// (the task was cancelled), which is not worth a line in the log.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }
        return false
    }
}
