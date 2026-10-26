@_exported import Foundation
#if canImport(FoundationNetworking)
@_exported import FoundationNetworking
#endif

enum ClickyWorkerConfiguration {
    static let workerBaseURL = "https://dottie.vidershub.workers.dev"
    static func url(forRoute routePath: String) -> URL { URL(string: workerBaseURL + routePath)! }
    static func applyAuthenticationHeaders(to request: inout URLRequest) {
        request.setValue("Dottie/1.0", forHTTPHeaderField: "User-Agent")
    }
}
