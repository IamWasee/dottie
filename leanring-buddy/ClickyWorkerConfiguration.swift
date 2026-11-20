//
//  ClickyWorkerConfiguration.swift
//  leanring-buddy
//
//  Where the app finds its Cloudflare Worker proxy. The Worker holds the
//  Gemini API key; the app only knows the Worker's URL and, optionally, a
//  shared secret that stops strangers from spending your free-tier quota.
//
//  Both values come from Info.plist so nothing needs to change in code:
//    ClickyWorkerBaseURL     e.g. https://dottie.yourname.workers.dev
//    ClickyAppSharedSecret   optional, must match APP_SHARED_SECRET on the Worker
//
//  The Release workflow writes them in when it builds Dottie.dmg. A copy
//  built without them asks for the address in Settings instead, which is
//  saved in UserDefaults and wins over Info.plist.
//

import Foundation

enum ClickyWorkerConfiguration {
    private static let placeholderWorkerBaseURL = "https://your-worker-name.your-subdomain.workers.dev"
    /// Set from Settings when the app wasn't built with an address.
    static let userWorkerBaseURLDefaultsKey = "clickyWorkerBaseURL"
    static let userAppSharedSecretDefaultsKey = "clickyAppSharedSecret"
    private static let installIdentifierDefaultsKey = "dottieInstallIdentifier"

    /// The address this copy of Dottie was built with, if any.
    static var builtInWorkerBaseURL: String? {
        guard let bundledBaseURL = AppBundleConfiguration.stringValue(forKey: "ClickyWorkerBaseURL"),
              bundledBaseURL != placeholderWorkerBaseURL else { return nil }
        return bundledBaseURL
    }

    private static var userWorkerBaseURL: String? {
        let savedBaseURL = UserDefaults.standard.string(forKey: userWorkerBaseURLDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return savedBaseURL.isEmpty ? nil : savedBaseURL
    }

    static var workerBaseURL: String {
        let configuredBaseURL = userWorkerBaseURL
            ?? builtInWorkerBaseURL
            ?? placeholderWorkerBaseURL
        // Tolerate a trailing slash so "https://x.workers.dev/" + "/chat" still works.
        return configuredBaseURL.hasSuffix("/") ? String(configuredBaseURL.dropLast()) : configuredBaseURL
    }

    static var isWorkerConfigured: Bool {
        workerBaseURL != placeholderWorkerBaseURL && URL(string: workerBaseURL)?.host != nil
    }

    /// The shared secret from Settings, else the one Dottie was built with.
    static var appSharedSecret: String? {
        let savedSecret = UserDefaults.standard.string(forKey: userAppSharedSecretDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return savedSecret.isEmpty ? AppBundleConfiguration.stringValue(forKey: "ClickyAppSharedSecret") : savedSecret
    }

    /// This copy of Dottie's own id, made up the first time it's needed and
    /// kept from then on. The Worker counts each install's requests for the
    /// day under it (worker/src/usageLimits.ts). It says nothing about the
    /// user or the Mac, and it isn't a secret.
    static var installIdentifier: String {
        // Requests start from many threads. Without the lock, two of them
        // on a fresh install could each make a different id, and one
        // request would be counted under an id that was never kept.
        installIdentifierLock.lock()
        defer { installIdentifierLock.unlock() }
        if let savedInstallIdentifier = UserDefaults.standard.string(forKey: installIdentifierDefaultsKey),
           !savedInstallIdentifier.isEmpty {
            return savedInstallIdentifier
        }
        let newInstallIdentifier = UUID().uuidString.lowercased()
        UserDefaults.standard.set(newInstallIdentifier, forKey: installIdentifierDefaultsKey)
        return newInstallIdentifier
    }
    private static let installIdentifierLock = NSLock()

    /// What Gemini CLI and the Gemini passthrough send as their "API key":
    /// the shared secret (any placeholder works without one) with the
    /// install id after it. The Worker checks the first part, counts under
    /// the second, and swaps in the real key.
    static var passthroughAPIKey: String {
        (appSharedSecret ?? "clicky-worker") + ":" + installIdentifier
    }

    static func url(forRoute routePath: String) -> URL {
        URL(string: workerBaseURL + routePath)
            ?? URL(string: placeholderWorkerBaseURL + routePath)!
    }

    enum HealthCheckResult: Equatable {
        case ready
        case missingGeminiKey
        case unreachable(String)
    }

    /// Asks the Worker's /health route whether it's up and has a key.
    static func checkHealth(ofBaseURL baseURLText: String) async -> HealthCheckResult {
        var trimmedBaseURL = baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmedBaseURL.hasSuffix("/") { trimmedBaseURL.removeLast() }
        guard let healthURL = URL(string: trimmedBaseURL + "/health"), healthURL.host != nil else {
            return .unreachable("That doesn't look like a web address.")
        }
        var request = URLRequest(url: healthURL)
        request.timeoutInterval = 15
        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let responseObject = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                  responseObject["ok"] as? Bool == true else {
                return .unreachable("Something answered, but it isn't a Dottie server (an older server may need redeploying).")
            }
            return responseObject["hasGeminiKey"] as? Bool == false ? .missingGeminiKey : .ready
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    /// Adds the shared-secret header when one is configured, and this
    /// install's id. Every request to the Worker goes through here so
    /// neither is ever forgotten.
    static func applyAuthenticationHeaders(to request: inout URLRequest) {
        if let appSharedSecret {
            request.setValue(appSharedSecret, forHTTPHeaderField: "x-clicky-secret")
        }
        request.setValue(installIdentifier, forHTTPHeaderField: "x-dottie-install")
    }
}
