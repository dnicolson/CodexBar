import Foundation
import Testing
@testable import CodexBarCore

struct KiroConnectivityGateTests {
    @Test(arguments: [URLError.Code.notConnectedToInternet, .timedOut, .cannotFindHost, .cancelled])
    func `a failed connectivity check stops the CLI probe`(code: URLError.Code) async {
        let transport = ProviderHTTPTransportStub { _ in throw URLError(code) }
        let strategy = KiroCLIFetchStrategy(
            connectivityGate: KiroConnectivityGate(transport: transport),
            makeProbe: {
                Issue.record("The CLI probe must not start after a failed connectivity check")
                return KiroStatusProbe(cliBinaryResolver: { nil })
            })

        await #expect(throws: URLError(code)) {
            try await strategy.fetch(Self.context())
        }
    }

    @Test(arguments: [200, 403, 503])
    func `an HTTP response lets the CLI probe run`(statusCode: Int) async throws {
        let transport = ProviderHTTPTransportStub { _ in (Data(), Self.kiroResponse(statusCode: statusCode)) }
        let strategy = KiroCLIFetchStrategy(
            connectivityGate: KiroConnectivityGate(transport: transport),
            makeProbe: { KiroStatusProbe(cliBinaryResolver: { nil }) })

        await #expect {
            try await strategy.fetch(Self.context())
        } throws: { error in
            guard case KiroStatusProbeError.cliNotFound = error else { return false }
            return true
        }
        let request = try #require(await transport.requests().first)
        #expect(request.httpMethod == "HEAD")
        #expect(request.url?.absoluteString == "https://app.kiro.dev/")
        #expect(request.timeoutInterval == 4)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test
    func `each refresh checks connectivity again`() async throws {
        let transport = ProviderHTTPTransportStub { _ in (Data(), Self.kiroResponse(statusCode: 200)) }
        let gate = KiroConnectivityGate(transport: transport)

        try await gate.ensureReachable()
        try await gate.ensureReachable()
        #expect(await transport.requests().count == 2)
    }

    private static func kiroResponse(statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://app.kiro.dev/")!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil)!
    }

    private static func context() -> ProviderFetchContext {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .cli,
            sourceMode: .auto,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: nil,
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }
}
