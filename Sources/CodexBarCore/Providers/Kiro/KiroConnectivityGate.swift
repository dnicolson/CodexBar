import Foundation

/// Checks connectivity before `kiro-cli` can open browser sign-in on a failed token refresh.
struct KiroConnectivityGate: Sendable {
    private let transport: any ProviderHTTPTransport

    init(transport: any ProviderHTTPTransport = KiroConnectivityGate.liveTransport) {
        self.transport = transport
    }

    func ensureReachable() async throws {
        var request = URLRequest(url: URL(string: "https://app.kiro.dev/")!, timeoutInterval: 4)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // Any HTTP response proves the host answers. Preserve network errors and cancellation.
        _ = try await self.transport.data(for: request)
    }

    private static let liveTransport: any ProviderHTTPTransport = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        #if !os(Linux)
        configuration.waitsForConnectivity = false
        #endif
        return ProviderHTTPClient(session: ProviderHTTPClient.redirectGuardedSession(configuration: configuration))
    }()
}
