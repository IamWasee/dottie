import AppKit
import Foundation
import ScreenCaptureKit

enum ClickyWorkerConfiguration {
    static func url(forRoute routePath: String) -> URL {
        URL(string: (ProcessInfo.processInfo.environment["W"] ?? "https://dottie.vidershub.workers.dev") + routePath)!
    }
    static func applyAuthenticationHeaders(to request: inout URLRequest) {
        request.setValue("Dottie/1.0", forHTTPHeaderField: "User-Agent")
    }
}

