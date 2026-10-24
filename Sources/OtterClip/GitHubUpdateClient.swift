import CryptoKit
import Foundation

struct UpdateRelease: Sendable {
    let version: String
    let tag: String
    let assetURL: URL
    /// A lowercase SHA-256 value without the algorithm prefix.
    let sha256: String
    let size: Int64
    let releaseURL: URL
    let notes: String
}

/// Releases deliberately accept stable three-part versions only. Numeric comparison
/// avoids treating 1.10.0 as older than 1.9.0 or accepting a prerelease as stable.
struct UpdateVersion: Comparable, Sendable {
    let rawValue: String
    private let components: [UInt64]

    init?(_ rawValue: String) {
        let parts = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var parsed: [UInt64] = []
        for part in parts {
            guard !part.isEmpty, (part.count == 1 || part.first != "0"),
                  part.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = UInt64(part) else { return nil }
            parsed.append(value)
        }
        self.rawValue = rawValue
        self.components = parsed
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

enum UpdateClientError: LocalizedError {
    case invalidCurrentVersion
    case invalidRelease
    case unsupportedArchitecture
    case missingPackage
    case missingDigest
    case invalidAssetURL
    case invalidSize
    case rateLimited
    case unavailable
    case network(String)
    case checksumMismatch
    case sizeMismatch
    case storage

    var errorDescription: String? {
        switch self {
        case .invalidCurrentVersion: return "无法识别当前应用版本，请从官方 GitHub 页面获取更新。"
        case .invalidRelease: return "GitHub 返回的版本信息无效，暂时无法更新。"
        case .unsupportedArchitecture: return "当前 Mac 的处理器架构暂不支持自动更新。"
        case .missingPackage: return "最新版本暂未提供适合这台 Mac 的更新包，请稍后重试。"
        case .missingDigest: return "更新包缺少有效的 SHA-256 校验信息，已停止更新。"
        case .invalidAssetURL: return "更新包地址不是 OtterClip 官方 GitHub 发布地址，已停止更新。"
        case .invalidSize: return "更新包大小异常，已停止更新。"
        case .rateLimited: return "GitHub 请求过于频繁，请稍后再检查更新。"
        case .unavailable: return "暂时无法获取 GitHub 更新，请稍后重试。"
        case .network(let reason): return "无法连接 GitHub：\(reason)"
        case .checksumMismatch: return "更新包校验失败，文件可能未完整下载，请重试。"
        case .sizeMismatch: return "更新包大小与发布信息不一致，请重新下载。"
        case .storage: return "无法保存更新包，请检查磁盘空间和目录权限后重试。"
        }
    }
}

struct GitHubUpdateClient {
    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unsupported"
        #endif
    }

    private static let endpoint = URL(string: "https://api.github.com/repos/dengbiao/OtterClip/releases/latest")!
    private static let maximumPackageSize: Int64 = 100 * 1_024 * 1_024
    private let session: URLSession

    init(session: URLSession = GitHubUpdateClient.makeSession()) {
        self.session = session
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }

    func check(currentVersion: String, architecture: String = Self.architecture) async throws -> UpdateRelease? {
        guard let current = UpdateVersion(currentVersion) else { throw UpdateClientError.invalidCurrentVersion }
        guard ["arm64", "x86_64"].contains(architecture) else { throw UpdateClientError.unsupportedArchitecture }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request(Self.endpoint, metadata: true))
        } catch { throw translatedNetworkError(error) }
        try validate(response)
        guard response.url == Self.endpoint else { throw UpdateClientError.invalidRelease }
        guard data.count <= 2 * 1_024 * 1_024,
              let payload = try? JSONDecoder().decode(ReleasePayload.self, from: data),
              !payload.draft, !payload.prerelease else { throw UpdateClientError.invalidRelease }
        let tag = payload.tagName
        let versionText = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard let version = UpdateVersion(versionText) else { throw UpdateClientError.invalidRelease }
        // No-op checks should still work when an older release has no updater ZIP.
        guard version > current else { return nil }
        let filename = "OtterClip-\(versionText)-\(architecture).zip"
        let matching = payload.assets.filter { $0.name == filename }
        guard matching.count == 1, let asset = matching.first else { throw UpdateClientError.missingPackage }
        guard asset.size > 0, asset.size <= Self.maximumPackageSize else { throw UpdateClientError.invalidSize }
        guard let digest = Self.parseDigest(asset.digest) else { throw UpdateClientError.missingDigest }
        guard let assetURL = URL(string: asset.browserDownloadURL),
              Self.isOfficialAssetURL(assetURL, tag: tag, filename: filename) else {
            throw UpdateClientError.invalidAssetURL
        }
        return UpdateRelease(version: versionText, tag: tag, assetURL: assetURL, sha256: digest,
                             size: asset.size,
                             releaseURL: URL(string: "https://github.com/dengbiao/OtterClip/releases/tag/\(tag)")!,
                             notes: payload.body ?? "")
    }

    func download(_ release: UpdateRelease, to directory: URL) async throws -> URL {
        let filename = release.assetURL.lastPathComponent
        guard UpdateVersion(release.version) != nil,
              release.tag == release.version || release.tag == "v" + release.version,
              ["arm64", "x86_64"].contains(where: { filename == "OtterClip-\(release.version)-\($0).zip" }),
              Self.isOfficialAssetURL(release.assetURL, tag: release.tag, filename: filename) else {
            throw UpdateClientError.invalidAssetURL
        }
        guard release.size > 0, release.size <= Self.maximumPackageSize else { throw UpdateClientError.invalidSize }
        guard Self.parseDigest("sha256:" + release.sha256) == release.sha256 else { throw UpdateClientError.missingDigest }
        let temporary: URL
        let response: URLResponse
        let transfer = UpdateDownloadGuard(maximumBytes: release.size)
        do {
            (temporary, response) = try await session.download(for: request(release.assetURL), delegate: transfer)
        } catch {
            if transfer.exceededSize { throw UpdateClientError.sizeMismatch }
            if transfer.insecureRedirect { throw UpdateClientError.invalidAssetURL }
            throw translatedNetworkError(error)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard !transfer.exceededSize else { throw UpdateClientError.sizeMismatch }
        guard !transfer.insecureRedirect else { throw UpdateClientError.invalidAssetURL }
        try validate(response)
        guard response.url?.scheme?.lowercased() == "https" else { throw UpdateClientError.invalidAssetURL }
        do {
            let properties = try temporary.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard properties.isRegularFile == true, properties.isSymbolicLink != true,
                  Int64(properties.fileSize ?? -1) == release.size else { throw UpdateClientError.sizeMismatch }
            var hash = SHA256()
            let file = try FileHandle(forReadingFrom: temporary)
            defer { try? file.close() }
            while let chunk = try file.read(upToCount: 1_024 * 1_024), !chunk.isEmpty { hash.update(data: chunk) }
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == release.sha256 else { throw UpdateClientError.checksumMismatch }
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // A unique destination avoids replacing a file from another update attempt.
            let destination = directory.appendingPathComponent(UUID().uuidString + "-" + filename)
            try FileManager.default.moveItem(at: temporary, to: destination)
            return destination
        } catch let error as UpdateClientError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw UpdateClientError.storage }
    }

    private func request(_ url: URL, metadata: Bool = false) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("OtterClip-Updater", forHTTPHeaderField: "User-Agent")
        request.setValue(metadata ? "application/vnd.github+json" : "application/octet-stream", forHTTPHeaderField: "Accept")
        if metadata { request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version") }
        return request
    }

    private func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw UpdateClientError.unavailable }
        if response.statusCode == 403 || response.statusCode == 429 { throw UpdateClientError.rateLimited }
        guard (200...299).contains(response.statusCode) else { throw UpdateClientError.unavailable }
    }

    private func translatedNetworkError(_ error: Error) -> Error {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return CancellationError() }
        let reason: String
        switch (error as? URLError)?.code {
        case .notConnectedToInternet: reason = "当前网络不可用，请检查互联网连接后重试。"
        case .timedOut: reason = "连接超时，请检查网络后重试。"
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost:
            reason = "连接中断或服务器不可达，请稍后重试。"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            reason = "无法验证服务器的安全连接，请检查系统时间和网络设置。"
        default: reason = "网络请求未能完成，请检查连接后重试。"
        }
        return UpdateClientError.network(reason)
    }

    private static func parseDigest(_ text: String?) -> String? {
        guard let text, text.hasPrefix("sha256:") else { return nil }
        let digest = String(text.dropFirst(7)).lowercased()
        guard digest.utf8.count == 64,
              digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return digest
    }

    private static func isOfficialAssetURL(_ url: URL, tag: String, filename: String) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme == "https" && components.host == "github.com"
            && components.user == nil && components.password == nil && components.port == nil
            && components.query == nil && components.fragment == nil
            && components.percentEncodedPath == "/dengbiao/OtterClip/releases/download/\(tag)/\(filename)"
    }

    private struct ReleasePayload: Decodable {
        let tagName: String
        let draft: Bool
        let prerelease: Bool
        let body: String?
        let assets: [AssetPayload]
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name", draft, prerelease, body, assets
        }
    }

    private struct AssetPayload: Decodable {
        let name: String
        let browserDownloadURL: String
        let size: Int64
        let digest: String?
        enum CodingKeys: String, CodingKey {
            case name, browserDownloadURL = "browser_download_url", size, digest
        }
    }
}

/// Cancels an unexpectedly large transfer while it is still writing to the
/// system's temporary download file. The final byte count and digest are checked
/// separately, because a server is allowed to omit its Content-Length header.
private final class UpdateDownloadGuard: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let maximumBytes: Int64
    private let lock = NSLock()
    private var sizeExceeded = false
    private var redirectedInsecurely = false
    var exceededSize: Bool { lock.withLock { sizeExceeded } }
    var insecureRedirect: Bool { lock.withLock { redirectedInsecurely } }

    init(maximumBytes: Int64) { self.maximumBytes = maximumBytes }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maximumBytes || totalBytesExpectedToWrite > maximumBytes {
            lock.withLock { sizeExceeded = true }
            downloadTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme?.lowercased() == "https" else {
            lock.withLock { redirectedInsecurely = true }
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
