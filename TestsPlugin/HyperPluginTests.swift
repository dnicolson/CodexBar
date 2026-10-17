import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct HyperPluginTests {
    #if canImport(JavaScriptCore)
    private static let engines: [ProviderPluginEngineKind] = [.quickJS, .javaScriptCore]
    #else
    private static let engines: [ProviderPluginEngineKind] = [.quickJS]
    #endif

    private static let teamID = "11111111-2222-3333-4444-555555555555"
    private static let authMeURL = "https://hyper.charm.land/auth/me"
    private static let dashboardURL = "https://hyper.charm.land/teams/\(Self.teamID)/dashboard"
    private static let creditsURL = "https://hyper.charm.land/v1/credits"

    /// `GET /auth/me` as the client-rendered app observes a live session: the account's team list.
    private static let signedIn = #"{"authenticated":true,"teams":[{"id":"\#(teamID)","name":"Fixture","role":"owner"}]}"#
    private static let signedOut = #"{"authenticated":false}"#

    /// `GET /teams/{id}/dashboard`: "Hypercredits Available" is subscription remaining plus prepaid.
    private static let dashboardJSON = #"{"refresh_at":1730000000,"returns_at":0,"now":0,"remaining":60,"prepaid":40,"available":60,"known":true,"limited":false,"subscribed":true}"#

    @Test(arguments: Self.engines)
    func `draft balance fixtures retain native HC without fabricated limits`(
        engine: ProviderPluginEngineKind) async throws
    {
        for balance in [0, 12, 18.5, 42.5] {
            let snapshot = try await Self.fetch(engine: engine, apiBody: "{\"balance\":\(balance)}")
            #expect(snapshot.providerCost == nil)
            #expect(snapshot.details.first?.rows.first?.usageValue == balance)
            #expect(snapshot.primary == nil)
            #expect(snapshot.secondary == nil)
            #expect(snapshot.identity?.providerID == .hyper)
            #expect(snapshot.identity?.loginMethod == "API key")
            #expect(snapshot.dataConfidence == .exact)
            #expect(snapshot.details.first?.rows.first?.value.hasSuffix(" HC") == true)
        }
    }

    @Test(arguments: Self.engines)
    func `session dashboard sums subscription and prepaid hypercredits`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await Self.fetch(
            engine: engine, cookie: "session=fixture-session",
            expectedRequests: [Self.authMeURL, Self.dashboardURL])
        #expect(snapshot.details.first?.rows.first?.usageValue == 100)
        #expect(snapshot.details.first?.rows.first?.value == "100 HC")
        #expect(snapshot.identity?.loginMethod == "Browser session")
        #expect(snapshot.dataConfidence == .exact)
        #expect(snapshot.primary == nil)
        #expect((snapshot.details.first?.rows ?? []).map(\.label) == ["Balance"])
    }

    @Test(arguments: Self.engines)
    func `automatic browser session works without an API key`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await Self.fetch(
            engine: engine, key: "", cookie: "session=fixture-session", cookieSource: .auto,
            expectedRequests: [Self.authMeURL, Self.dashboardURL])
        #expect(snapshot.details.first?.rows.first?.usageValue == 100)
        #expect(snapshot.identity?.loginMethod == "Browser session")
    }

    @Test(arguments: Self.engines)
    func `API source bypasses cookie resolver`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await Self.fetch(engine: engine, cookie: "session=unused", mode: .api)
        #expect(snapshot.identity?.loginMethod == "API key")
    }

    @Test(arguments: Self.engines)
    func `missing session falls back to key`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await Self.fetch(engine: engine, cookie: "")
        #expect(snapshot.identity?.loginMethod == "API key")
    }

    @Test(arguments: [
        (200, Self.signedOut),
        (401, #"{}"#),
        (500, #"{}"#),
    ], Self.engines)
    func `expired session is rejected before API fallback`(
        fixture: (Int, String),
        engine: ProviderPluginEngineKind) async throws
    {
        let snapshot = try await Self.fetch(
            engine: engine, cookie: "session=fixture-rejected-session",
            authMeStatus: fixture.0, authMeBody: fixture.1)
        #expect(snapshot.identity?.loginMethod == "API key")
    }

    @Test(arguments: [
        (200, Self.signedOut),
        (401, #"{}"#),
        (500, #"{}"#),
    ], Self.engines)
    func `web only never falls back to configured key`(
        fixture: (Int, String),
        engine: ProviderPluginEngineKind) async
    {
        do {
            _ = try await Self.fetch(
                engine: engine, cookie: "session=fixture-rejected-session", mode: .web,
                authMeStatus: fixture.0, authMeBody: fixture.1)
            Issue.record("Expected expired session")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .authenticationExpired)
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test(arguments: [
        (ProviderCookieSource.manual, "Paste a fresh Cookie header in Settings"),
        (ProviderCookieSource.auto, "Sign in again at hyper.charm.land"),
    ], Self.engines)
    func `expired session guidance matches the cookie source`(
        expected: (ProviderCookieSource, String),
        engine: ProviderPluginEngineKind) async
    {
        do {
            _ = try await Self.fetch(
                engine: engine, key: "", cookie: "session=fixture-expired", cookieSource: expected.0,
                authMeBody: Self.signedOut)
            Issue.record("Expected expired session")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .authenticationExpired)
            #expect(error.message.contains(expected.1))
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test(arguments: [
        #"{}"#,
        #"{"returns_at":1730000000}"#,
        #"{"remaining":"100"}"#,
        #"{"remaining":1e400}"#,
        #"{"remaining":null,"prepaid":null}"#,
    ], Self.engines)
    func `dashboard without a parseable balance fails closed instead of guessing`(
        body: String,
        engine: ProviderPluginEngineKind) async
    {
        do {
            _ = try await Self.fetch(
                engine: engine, cookie: "session=fixture", mode: .web, dashboardBody: body)
            Issue.record("Expected parse failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .parseFailure)
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test(arguments: [
        "",
        "{}",
        #"{"balance":"#,
        #"{"balance":-1}"#,
        #"{"balance":"invalid"}"#,
        #"{"balance":null}"#,
        #"{"balance":true}"#,
        #"{"balance":1e400}"#,
        "null",
        "[]"
    ], Self.engines)
    func `malformed API balances fail closed`(
        body: String, engine: ProviderPluginEngineKind) async
    {
        do {
            _ = try await Self.fetch(
                engine: engine, apiBody: body)
            Issue.record("Expected parse failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .parseFailure)
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test(arguments: [
        (401, ProviderFetchClassifiedError.Kind.authenticationExpired),
        (403, .permissionDenied),
        (429, .rateLimited),
        (503, .providerUnavailable),
        (404, .apiFailure)
    ], Self.engines)
    func `HTTP errors are classified without exposing response or key`(
        fixture: (Int, ProviderFetchClassifiedError.Kind), engine: ProviderPluginEngineKind) async
    {
        do {
            _ = try await Self.fetch(
                engine: engine, apiBody: "private upstream body fixture-key", apiStatus: fixture.0)
            Issue.record("Expected HTTP failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == fixture.1)
            #expect(!error.message.contains("private upstream body"))
            #expect(!error.message.contains("fixture-key"))
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test(arguments: Self.engines)
    func `no credentials produce guidance without HTTP`(engine: ProviderPluginEngineKind) async {
        do {
            _ = try await Self.fetch(engine: engine, key: "", expectedRequests: [])
            Issue.record("Expected missing credential")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .missingCredential)
            #expect(error.message.contains("Sign in"))
            #expect(error.message.contains("API key"))
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test
    func `registry projects config and keeps balance provider opt in`() throws {
        let descriptor = HyperProviderDescriptor.descriptor
        let credentials = try #require(descriptor.credentials)
        let environment = credentials.applyConfig(
            base: ["HYPER_API_KEY": "old-key", "OTHER": "preserved"],
            config: ProviderConfig(id: .hyper, apiKey: " 'fixture-key' "))
        #expect(credentials.resolveToken(environment: environment)?.token == "fixture-key")
        #expect(environment["OTHER"] == "preserved")
        #expect(HyperProviderDescriptor.apiKey(environment: ["HYPER_API_KEY": "  "]) == nil)
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .web, .api])
        #expect(!descriptor.metadata.defaultEnabled)
        #expect(!descriptor.metadata.widgetSelectable)
        #expect(descriptor.metadata.balanceOnly)
        if case let .environment(key) = credentials.tokenAccountSupport?.injection {
            #expect(key == "HYPER_API_KEY")
        } else {
            Issue.record("Expected API-key token accounts")
        }
    }

    @Test(arguments: Self.engines)
    func `stale session candidates advance to a later browser within one refresh`(
        engine: ProviderPluginEngineKind) async throws
    {
        let sessions = HyperSessionTrace(headers: ["session=stale-fixture", "session=live-fixture"])
        let runtime = try Self.runtime(engine: engine, transport: ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            let header = request.value(forHTTPHeaderField: "Cookie") ?? ""
            if url.absoluteString == Self.authMeURL {
                sessions.request(header)
                let stale = header.contains("stale-fixture")
                let response = try #require(HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]))
                return (Data((stale ? Self.signedOut : Self.signedIn).utf8), response)
            }
            #expect(url.absoluteString == Self.dashboardURL)
            #expect(header == "session=live-fixture")
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]))
            return (Data(Self.dashboardJSON.utf8), response)
        })
        let result = try await runtime.fetchResult(
            settings: ["SOURCE_MODE": ProviderSourceMode.auto.rawValue], secrets: ["HYPER_API_KEY": ""],
            sourceMode: .auto, cookieSource: .auto,
            cookieSessionResolver: { domain, _ in
                #expect(domain == "hyper.charm.land")
                return sessions.next()
            },
            cookieSessionInvalidator: { domain, id in
                #expect(domain == "hyper.charm.land")
                sessions.reject(id)
            })
        #expect(result.usage.details.first?.rows.first?.usageValue == 100)
        #expect(result.usage.identity?.loginMethod == "Browser session")
        #expect(result.sourceLabel == "web")
        #expect(sessions.requested == ["session=stale-fixture", "session=live-fixture"])
        #expect(sessions.rejected == [sessions.candidates[0].id])
    }

    @Test(arguments: Self.engines)
    func `every rejected candidate falls back to the configured API key`(
        engine: ProviderPluginEngineKind) async throws
    {
        let sessions = HyperSessionTrace(headers: ["session=stale-one", "session=stale-two"])
        let runtime = try Self.runtime(engine: engine, transport: ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            if url.absoluteString == Self.authMeURL {
                sessions.request(request.value(forHTTPHeaderField: "Cookie") ?? "")
                let response = try #require(HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]))
                return (Data(Self.signedOut.utf8), response)
            }
            #expect(url.absoluteString == Self.creditsURL)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
            return (Data(#"{"balance":42.5}"#.utf8), response)
        })
        let result = try await runtime.fetchResult(
            settings: ["SOURCE_MODE": ProviderSourceMode.auto.rawValue], secrets: ["HYPER_API_KEY": "fixture-key"],
            sourceMode: .auto, cookieSource: .auto,
            cookieSessionResolver: { _, _ in sessions.next() },
            cookieSessionInvalidator: { _, id in sessions.reject(id) })
        #expect(result.usage.identity?.loginMethod == "API key")
        #expect(result.sourceLabel == "api")
        #expect(sessions.requested == ["session=stale-one", "session=stale-two"])
        #expect(sessions.rejected == sessions.candidates.map(\.id))
    }

    @Test(arguments: Self.engines)
    func `manual source stops after the pasted candidate`(engine: ProviderPluginEngineKind) async throws {
        let sessions = HyperSessionTrace(headers: ["session=stale-one", "session=stale-two"])
        let runtime = try Self.runtime(engine: engine, transport: ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            #expect(url.absoluteString == Self.authMeURL)
            #expect(request.value(forHTTPHeaderField: "Cookie") == "session=stale-one")
            sessions.request(request.value(forHTTPHeaderField: "Cookie") ?? "")
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]))
            return (Data(Self.signedOut.utf8), response)
        })
        do {
            _ = try await runtime.fetchResult(
                settings: ["SOURCE_MODE": ProviderSourceMode.auto.rawValue], secrets: ["HYPER_API_KEY": ""],
                sourceMode: .auto, cookieSource: .manual,
                cookieSessionResolver: { _, _ in sessions.next() },
                cookieSessionInvalidator: { _, id in sessions.reject(id) })
            Issue.record("Expected expired session")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .authenticationExpired)
            #expect(error.message.contains("Paste a fresh Cookie header"))
        }
        #expect(sessions.consumed == 1)
        #expect(sessions.rejected == [sessions.candidates[0].id])
    }

    private static func runtime(
        engine: ProviderPluginEngineKind,
        transport: ProviderHTTPTransportHandler) throws -> ProviderPluginRuntime
    {
        let url = try #require(CodexBarCoreResources.bundle?.url(forResource: "hyper", withExtension: "js"))
        return try ProviderPluginRuntime(
            source: String(contentsOf: url, encoding: .utf8), transport: transport, engine: engine)
    }

    private static func fetch(
        engine: ProviderPluginEngineKind,
        apiBody: String = #"{"balance":42.5}"#,
        key: String = "fixture-key",
        cookie: String? = nil,
        cookieSource: ProviderCookieSource? = nil,
        mode: ProviderSourceMode = .auto,
        authMeStatus: Int = 200,
        authMeBody: String = Self.signedIn,
        dashboardStatus: Int = 200,
        dashboardBody: String = Self.dashboardJSON,
        apiStatus: Int = 200,
        expectedRequests: [String]? = nil) async throws -> UsageSnapshot
    {
        let rejected = HyperRejectionRecorder()
        let requests = HyperRequestRecorder()
        let source = cookieSource ?? (cookie == nil ? .off : .manual)
        let expectsSession = cookie?.isEmpty == false && mode != .api && source != .off
        let sessionSucceeded = expectsSession && authMeStatus == 200 && authMeBody.contains("\"authenticated\":true")
        let transport = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            requests.record(url.absoluteString)
            if url.absoluteString == "https://hyper.charm.land/auth/me" {
                #expect(expectsSession)
                #expect(request.value(forHTTPHeaderField: "Cookie") == cookie)
                #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
                let response = try #require(HTTPURLResponse(
                    url: url, statusCode: authMeStatus, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]))
                return (Data(authMeBody.utf8), response)
            }
            if url.absoluteString == Self.dashboardURL {
                #expect(sessionSucceeded)
                #expect(request.value(forHTTPHeaderField: "Cookie") == cookie)
                let response = try #require(HTTPURLResponse(
                    url: url, statusCode: dashboardStatus, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]))
                return (Data(dashboardBody.utf8), response)
            }
            #expect(url.absoluteString == "https://hyper.charm.land/v1/credits")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(key)")
            #expect(mode != .web)
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: apiStatus, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]))
            return (Data(apiBody.utf8), response)
        }
        let url = try #require(CodexBarCoreResources.bundle?.url(forResource: "hyper", withExtension: "js"))
        let runtime = try ProviderPluginRuntime(
            source: String(contentsOf: url, encoding: .utf8), transport: transport, engine: engine)
        let result = try await runtime.fetchResult(
            settings: ["SOURCE_MODE": mode.rawValue], secrets: ["HYPER_API_KEY": key],
            sourceMode: mode, cookieSource: source,
            cookieInvalidator: { domain in
                #expect(domain == "hyper.charm.land")
                rejected.record()
            },
            cookieResolver: { provider, domain in
                #expect(mode != .api)
                #expect(provider == .hyper)
                #expect(domain == "hyper.charm.land")
                guard let cookie, !cookie.isEmpty else { throw ProviderPluginError.secretAccess("fixture missing") }
                return cookie
            })
        #expect(result.sourceLabel == (sessionSucceeded ? "web" : "api"))
        #expect(rejected.count == (expectsSession && !sessionSucceeded ? 1 : 0))
        if let expectedRequests {
            #expect(requests.urls == expectedRequests)
        }
        return result.usage
    }
}

private final class HyperSessionTrace: @unchecked Sendable {
    let candidates: [ProviderPluginCookieSession]
    private let lock = NSLock()
    private var index = 0
    private var requests: [String] = []
    private var rejections: [String] = []

    init(headers: [String]) {
        self.candidates = headers.map {
            ProviderPluginCookieSession(header: $0, source: "Fixture", origin: "https://hyper.charm.land")
        }
    }

    func next() -> ProviderPluginCookieSession? {
        self.lock.withLock {
            guard self.index < self.candidates.count else { return nil }
            defer { self.index += 1 }
            return self.candidates[self.index]
        }
    }

    func request(_ header: String) { self.lock.withLock { self.requests.append(header) } }
    func reject(_ id: String) { self.lock.withLock { self.rejections.append(id) } }
    var consumed: Int {
        self.lock.withLock { self.index }
    }

    var requested: [String] {
        self.lock.withLock { self.requests }
    }

    var rejected: [String] {
        self.lock.withLock { self.rejections }
    }
}

private final class HyperRejectionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int {
        self.lock.withLock { self.value }
    }

    func record() { self.lock.withLock { self.value += 1 } }
}

private final class HyperRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [String] = []
    var urls: [String] {
        self.lock.withLock { self.value }
    }

    func record(_ url: String) { self.lock.withLock { self.value.append(url) } }
}
