import CryptoKit
import Foundation

/// Uses URLProtocol fixtures and temporary downloads; never contacts GitHub or
/// accesses the user's clipboard, history, preferences, or installed app.
enum UpdateClientChecks {
    static func run() async -> Int32 {
        var failures = 0
        var count = 0
        func check(_ label: String, _ success: Bool) {
            count += 1
            if success { print("PASS \(label)") }
            else { failures += 1; fputs("FAIL \(label)\n", stderr) }
        }
        func expectFailure(_ label: String, matching predicate: (Error) -> Bool,
                           operation: () async throws -> Void) async {
            do {
                try await operation()
                check(label, false)
            } catch { check(label, predicate(error)) }
        }
        let fixture = UpdateHTTPFixture()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateFixtureProtocol.self]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); UpdateFixtureProtocol.setFixture(nil) }
        UpdateFixtureProtocol.setFixture(fixture)
        let client = GitHubUpdateClient(session: session)
        let bytes = Data("PK\u{03}\u{04}OtterClip update fixture\n".utf8)
        let checksum = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let assetName = "OtterClip-1.10.0-arm64.zip"
        let assetURL = URL(string: "https://github.com/dengbiao/OtterClip/releases/download/v1.10.0/\(assetName)")!
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("OtterClipUpdateChecks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }

        func payload(tag: String = "v1.10.0", draft: Bool = false, prerelease: Bool = false,
                     name: String? = nil, url: String? = nil, digest: String? = nil,
                     size: Int64? = nil, emptyAssets: Bool = false) -> Data {
            let asset: [String: Any] = ["name": name ?? assetName,
                                       "browser_download_url": url ?? assetURL.absoluteString,
                                       "size": size ?? Int64(bytes.count),
                                       "digest": digest ?? "sha256:\(checksum)"]
            let value: [String: Any] = ["tag_name": tag, "draft": draft, "prerelease": prerelease,
                                        "body": "更新说明", "assets": emptyAssets ? [] : [asset]]
            return try! JSONSerialization.data(withJSONObject: value)
        }
        func use(_ body: Data, status: Int = 200, error: URLError? = nil, finalURL: URL? = nil) {
            fixture.set(response: .init(data: body, status: status, error: error, responseURL: finalURL))
        }
        func checkError(_ value: Error, _ predicate: (UpdateClientError) -> Bool) -> Bool {
            guard let error = value as? UpdateClientError else { return false }
            return predicate(error)
        }

        check("versions compare numeric components", UpdateVersion("1.10.0")! > UpdateVersion("1.9.9")!)
        check("major version comparison takes precedence", UpdateVersion("2.0.0")! > UpdateVersion("1.99.99")!)
        check("stable parser rejects malformed and prerelease versions",
              ["1.2", "1.2.3.4", "01.2.3", "1.02.3", "1.2.3-beta", "1.2.3+build", "v1.2.3", "１.2.3", "1.-2.3", "1..3", " 1.2.3", "18446744073709551616.0.0"]
                .allSatisfy { UpdateVersion($0) == nil })
        let privateSession = GitHubUpdateClient.makeSession()
        let privateConfiguration = privateSession.configuration
        check("default updater session disables cached responses, cookies, and credentials",
              privateConfiguration.urlCache == nil && privateConfiguration.httpCookieStorage == nil
              && privateConfiguration.urlCredentialStorage == nil && !privateConfiguration.httpShouldSetCookies
              && privateConfiguration.timeoutIntervalForRequest == 30
              && privateConfiguration.timeoutIntervalForResource == 300)
        privateSession.invalidateAndCancel()
        use(payload())
        var validRelease: UpdateRelease?
        do {
            let release = try await client.check(currentVersion: "1.9.9", architecture: "arm64")
            validRelease = release
            check("higher stable official release produces a matching package",
                  release?.version == "1.10.0" && release?.tag == "v1.10.0"
                  && release?.assetURL == assetURL && release?.sha256 == checksum
                  && release?.size == Int64(bytes.count) && release?.notes == "更新说明"
                  && release?.releaseURL.absoluteString == "https://github.com/dengbiao/OtterClip/releases/tag/v1.10.0")
            let request = fixture.lastRequest
            check("update requests contain only public updater metadata",
                  request?.url?.absoluteString == "https://api.github.com/repos/dengbiao/OtterClip/releases/latest"
                  && request?.httpMethod == "GET" && request?.httpBody == nil
                  && request?.value(forHTTPHeaderField: "Authorization") == nil
                  && request?.value(forHTTPHeaderField: "Cookie") == nil)
        } catch { check("higher stable official release produces a matching package", false) }

        use(payload(emptyAssets: true))
        do { check("same version without updater ZIP is already current", try await client.check(currentVersion: "1.10.0", architecture: "arm64") == nil) }
        catch { check("same version without updater ZIP is already current", false) }
        do { check("older server version never downgrades", try await client.check(currentVersion: "2.0.0", architecture: "arm64") == nil) }
        catch { check("older server version never downgrades", false) }
        let intelName = "OtterClip-1.10.0-x86_64.zip"
        use(payload(name: intelName, url: "https://github.com/dengbiao/OtterClip/releases/download/v1.10.0/\(intelName)"))
        do {
            let release = try await client.check(currentVersion: "1.9.0", architecture: "x86_64")
            check("Intel Macs select the x86_64 package", release?.assetURL.lastPathComponent == intelName)
        } catch { check("Intel Macs select the x86_64 package", false) }
        await expectFailure("invalid installed version cannot trigger an update", matching: {
            checkError($0) { if case .invalidCurrentVersion = $0 { return true }; return false }
        }) { _ = try await client.check(currentVersion: "broken", architecture: "arm64") }
        await expectFailure("unsupported processor has a clear failure", matching: {
            checkError($0) { if case .unsupportedArchitecture = $0 { return true }; return false }
        }) { _ = try await client.check(currentVersion: "1.0.0", architecture: "i386") }

        for (label, body) in [
            ("draft releases are rejected", payload(draft: true)),
            ("prereleases are rejected", payload(prerelease: true)),
            ("prerelease tags are rejected even with an incorrect stable flag", payload(tag: "v1.10.0-beta")),
            ("malformed release JSON is rejected", Data("{}".utf8))
        ] {
            use(body)
            await expectFailure(label, matching: {
                checkError($0) { if case .invalidRelease = $0 { return true }; return false }
            }) { _ = try await client.check(currentVersion: "1.0.0", architecture: "arm64") }
        }
        for (label, body) in [
            ("package must match the requested processor", payload(name: "OtterClip-1.10.0-x86_64.zip")),
            ("missing ZIP produces a useful error", payload(emptyAssets: true))
        ] {
            use(body)
            await expectFailure(label, matching: {
                checkError($0) { if case .missingPackage = $0 { return true }; return false }
            }) { _ = try await client.check(currentVersion: "1.0.0", architecture: "arm64") }
        }
        for (label, url) in [
            ("package repository must be official", "https://github.com/someone/OtterClip/releases/download/v1.10.0/\(assetName)"),
            ("package transport must use HTTPS", assetURL.absoluteString.replacingOccurrences(of: "https:", with: "http:")),
            ("package URL cannot hide a different host in credentials", "https://github.com@evil.invalid/dengbiao/OtterClip/releases/download/v1.10.0/\(assetName)"),
            ("package URL must have no extra query", assetURL.absoluteString + "?redirect=elsewhere"),
            ("package URL tag must match the release", assetURL.absoluteString.replacingOccurrences(of: "/v1.10.0/", with: "/v1.11.0/")),
            ("package URL filename must match the asset", assetURL.absoluteString.replacingOccurrences(of: "-arm64.zip", with: "-x86_64.zip")),
            ("encoded path separators are rejected", assetURL.absoluteString.replacingOccurrences(of: "/releases/", with: "%2Freleases/"))
        ] {
            use(payload(url: url))
            await expectFailure(label, matching: {
                checkError($0) { if case .invalidAssetURL = $0 { return true }; return false }
            }) { _ = try await client.check(currentVersion: "1.0.0", architecture: "arm64") }
        }
        for digest in ["", "md5:" + String(repeating: "a", count: 64), "sha256:abcd", "sha256:" + String(repeating: "z", count: 64)] {
            use(payload(digest: digest))
            await expectFailure("invalid asset digest is rejected: \(digest.prefix(12))", matching: {
                checkError($0) { if case .missingDigest = $0 { return true }; return false }
            }) { _ = try await client.check(currentVersion: "1.0.0", architecture: "arm64") }
        }
        for size: Int64 in [0, -1, 100 * 1_024 * 1_024 + 1] {
            use(payload(size: size))
            await expectFailure("invalid asset size is rejected: \(size)", matching: {
                checkError($0) { if case .invalidSize = $0 { return true }; return false }
            }) { _ = try await client.check(currentVersion: "1.0.0", architecture: "arm64") }
        }
        use(payload(), finalURL: URL(string: "https://api.github.com/repos/someone/OtterClip/releases/latest")!)
        await expectFailure("metadata cannot redirect to another repository", matching: {
            checkError($0) { if case .invalidRelease = $0 { return true }; return false }
        }) { _ = try await client.check(currentVersion: "1.0.0", architecture: "arm64") }
        for status in [403, 429] {
            use(Data(), status: status)
            await expectFailure("GitHub HTTP \(status) explains request limits", matching: {
                checkError($0) { if case .rateLimited = $0 { return true }; return false }
            }) { _ = try await client.check(currentVersion: "1.0.0", architecture: "arm64") }
        }
        use(Data(), status: 500)
        await expectFailure("GitHub server failure does not become an available update", matching: {
            checkError($0) { if case .unavailable = $0 { return true }; return false }
        }) { _ = try await client.check(currentVersion: "1.0.0", architecture: "arm64") }
        use(Data(), error: URLError(.notConnectedToInternet))
        await expectFailure("offline errors explain the network problem", matching: {
            checkError($0) { if case .network = $0 { return true }; return false }
        }) { _ = try await client.check(currentVersion: "1.0.0", architecture: "arm64") }
        use(Data(), error: URLError(.cancelled))
        await expectFailure("cancelled request remains cancellation", matching: { $0 is CancellationError }) {
            _ = try await client.check(currentVersion: "1.0.0", architecture: "arm64")
        }

        if let release = validRelease {
            use(bytes)
            do {
                let file = try await client.download(release, to: temporary)
                let saved = try Data(contentsOf: file)
                check("download saves verified ZIP bytes inside the update directory",
                      saved == bytes && file.pathExtension == "zip"
                      && file.deletingLastPathComponent().standardizedFileURL == temporary.standardizedFileURL)
                try FileManager.default.removeItem(at: file)
            } catch {
                fputs("Download fixture: \(error)\n", stderr)
                check("download saves verified ZIP bytes inside the update directory", false)
            }
            let corrupt = Data(repeating: 0, count: bytes.count)
            use(corrupt)
            await expectFailure("same-size corrupt download fails SHA-256 verification", matching: {
                checkError($0) { if case .checksumMismatch = $0 { return true }; return false }
            }) { _ = try await client.download(release, to: temporary) }
            use(Data(bytes.dropLast()))
            await expectFailure("truncated download fails size verification", matching: {
                checkError($0) { if case .sizeMismatch = $0 { return true }; return false }
            }) { _ = try await client.download(release, to: temporary) }
            use(bytes + Data(repeating: 0, count: 8_192))
            await expectFailure("download larger than the published size is stopped", matching: {
                checkError($0) { if case .sizeMismatch = $0 { return true }; return false }
            }) { _ = try await client.download(release, to: temporary) }
            use(bytes, finalURL: URL(string: "http://release-assets.githubusercontent.com/insecure.zip")!)
            await expectFailure("download cannot finish over insecure HTTP", matching: {
                checkError($0) { if case .invalidAssetURL = $0 { return true }; return false }
            }) { _ = try await client.download(release, to: temporary) }
            use(bytes, finalURL: URL(string: "https://release-assets.githubusercontent.com/official-cdn.zip")!)
            do {
                let file = try await client.download(release, to: temporary)
                check("GitHub HTTPS asset CDN redirect is supported after digest verification", try Data(contentsOf: file) == bytes)
                try FileManager.default.removeItem(at: file)
            } catch { check("GitHub HTTPS asset CDN redirect is supported after digest verification", false) }
            let invalidRelease = UpdateRelease(version: release.version, tag: release.tag,
                                               assetURL: URL(string: "https://evil.invalid/\(assetName)")!,
                                               sha256: release.sha256, size: release.size,
                                               releaseURL: release.releaseURL, notes: release.notes)
            let requestCount = fixture.requestCount
            await expectFailure("download revalidates its public release input", matching: {
                checkError($0) { if case .invalidAssetURL = $0 { return true }; return false }
            }) { _ = try await client.download(invalidRelease, to: temporary) }
            check("invalid download never sends a network request", fixture.requestCount == requestCount)
            check("failed downloads leave no installation payload",
                  ((try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? []).isEmpty)
        } else { check("download checks have valid release metadata", false) }
        print("Update client checks: \(count - failures)/\(count) passed")
        return failures == 0 ? 0 : 1
    }
}

private final class UpdateHTTPFixture: @unchecked Sendable {
    struct Response {
        let data: Data
        var status: Int = 200
        var error: URLError?
        var responseURL: URL?
    }
    private let lock = NSLock()
    private var response = Response(data: Data())
    private var requests: [URLRequest] = []
    var lastRequest: URLRequest? { lock.withLock { requests.last } }
    var requestCount: Int { lock.withLock { requests.count } }
    func set(response: Response) { lock.withLock { self.response = response } }
    func respond(to request: URLRequest) -> Response {
        lock.withLock { requests.append(request); return response }
    }
}

private final class UpdateFixtureProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var fixture: UpdateHTTPFixture?
    static func setFixture(_ value: UpdateHTTPFixture?) { lock.withLock { fixture = value } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = Self.lock.withLock({ Self.fixture }), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return
        }
        let value = fixture.respond(to: request)
        if let error = value.error { client?.urlProtocol(self, didFailWithError: error); return }
        let response = HTTPURLResponse(url: value.responseURL ?? url, statusCode: value.status,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(value.data.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: value.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
