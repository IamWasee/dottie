//
//  ClickyWorkerConfiguration.swift
//  leanring-buddy
//
//  Where the app finds its Cloudflare Worker proxy. The Worker holds the
//  Gemini API key; the app only knows the Worker's URL and, optionally, a
//  shared secret that stops strangers from spending your free-tier quota.
//
//  Both values come from Info.plist so nothing needs to change in code:
//    ClickyWorkerBaseURL     e.g. https://clicky-proxy.yourname.workers.dev
//    ClickyAppSharedSecret   optional, must match APP_SHARED_SECRET on the Worker
//

import Foundation

enum ClickyWorkerConfiguration {
    private static let placeholderWorkerBaseURL = "https://your-worker-name.your-subdomain.workers.dev"

    static var workerBaseURL: String {
        let configuredBaseURL = AppBundleConfiguration.stringValue(forKey: "ClickyWorkerBaseURL")
            ?? placeholderWorkerBaseURL
        // Tolerate a trailing slash so "https://x.workers.dev/" + "/chat" still works.
        return configuredBaseURL.hasSuffix("/") ? String(configuredBaseURL.dropLast()) : configuredBaseURL
    }

    static var isWorkerConfigured: Bool {
        workerBaseURL != placeholderWorkerBaseURL
    }

    static func url(forRoute routePath: String) -> URL {
        URL(string: workerBaseURL + routePath)!
    }

    /// Adds the shared-secret header when one is configured. Every request to
    /// the Worker goes through here so the header is never forgotten.
    static func applyAuthenticationHeaders(to request: inout URLRequest) {
        if let appSharedSecret = AppBundleConfiguration.stringValue(forKey: "ClickyAppSharedSecret") {
            request.setValue(appSharedSecret, forHTTPHeaderField: "x-clicky-secret")
        }
    }
}
